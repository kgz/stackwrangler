#!/usr/bin/env bash
# #252: host-mode task-role credentials without mutating host iptables.
# Image without iptables; FULL_URI on 127.0.0.1 + Authorization token.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_HOST_CREDS_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

CLUSTER="awsbox-ecs-hc-${TS}"
TASK_ROLE="awsbox-ecs-hc-role-${TS}"
TASK_ARNS=()
DOCKER_NAME=""

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	for arn in "${TASK_ARNS[@]:-}"; do
		aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$TASK_ROLE" --policy-name sts >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$TASK_ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> create IAM role + cluster"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$TASK_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$TASK_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name sts --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}' >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

# busybox/curl image has no iptables — DNAT path would exit 127.
FAMILY="awsbox-ecs-hc-${TS}"
# shellcheck disable=SC2016
CDEFS=$(cat <<'EOF'
[{
  "name": "cred",
  "image": "curlimages/curl:8.5.0",
  "essential": true,
  "memory": 64,
  "command": ["sh", "-c", "sleep 3600"]
}]
EOF
)

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode host \
	--task-role-arn "$ROLE_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$TASK_ARN")
TASK_ID="${TASK_ARN##*/}"

STATUS=""
for _ in $(seq 1 60); do
	STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)"
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
[[ "$STATUS" == "RUNNING" ]] || {
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" >&2
	fail "host-mode task not RUNNING (status=${STATUS})"
}

DOCKER_NAME="$(
	docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1
)"
[[ -n "$DOCKER_NAME" ]] || fail "no docker container for task"

# Env: FULL_URI + token; no RELATIVE_URI
ENV_DUMP="$(docker exec "$DOCKER_NAME" sh -c 'env' 2>/dev/null || true)"
echo "$ENV_DUMP" | grep -q '^AWS_CONTAINER_CREDENTIALS_FULL_URI=http://127.0.0.1:' \
	|| fail "missing AWS_CONTAINER_CREDENTIALS_FULL_URI on 127.0.0.1"
echo "$ENV_DUMP" | grep -q '^AWS_CONTAINER_AUTHORIZATION_TOKEN=.' \
	|| fail "missing AWS_CONTAINER_AUTHORIZATION_TOKEN"
if echo "$ENV_DUMP" | grep -q '^AWS_CONTAINER_CREDENTIALS_RELATIVE_URI='; then
	fail "RELATIVE_URI must not be set in host mode"
fi

FULL_URI="$(echo "$ENV_DUMP" | sed -n 's/^AWS_CONTAINER_CREDENTIALS_FULL_URI=//p')"
TOKEN="$(echo "$ENV_DUMP" | sed -n 's/^AWS_CONTAINER_AUTHORIZATION_TOKEN=//p')"
CREDS_JSON="$(docker exec "$DOCKER_NAME" sh -c "curl -sf -H \"Authorization: ${TOKEN}\" \"${FULL_URI}\"")"
echo "$CREDS_JSON" | grep -q "$ROLE_ARN" || fail "creds RoleArn mismatch: ${CREDS_JSON}"
echo "$CREDS_JSON" | grep -q AccessKeyId || fail "creds missing AccessKeyId"

# Wrong task id → 404 (or 403 if token required for that id)
BAD_URI="${FULL_URI%/*}/deadbeefdeadbeefdeadbeefdeadbeef"
BAD_CODE="$(docker exec "$DOCKER_NAME" sh -c "curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: ${TOKEN}\" \"${BAD_URI}\"" || true)"
[[ "$BAD_CODE" == "404" || "$BAD_CODE" == "403" ]] \
	|| fail "expected 403/404 for other task id, got ${BAD_CODE}"

# Wrong/missing Authorization → 403
NOAUTH_CODE="$(docker exec "$DOCKER_NAME" sh -c "curl -s -o /dev/null -w '%{http_code}' \"${FULL_URI}\"" || true)"
[[ "$NOAUTH_CODE" == "403" ]] || fail "expected 403 without token, got ${NOAUTH_CODE}"

# sts get-caller-identity with the minted session (same keys the task would use)
AK="$(echo "$CREDS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])')"
SK="$(echo "$CREDS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])')"
TK="$(echo "$CREDS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Token"])')"
IDENT="$(
	AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$TK" \
		aws sts get-caller-identity --query Arn --output text
)"
echo "$IDENT" | grep -q "$TASK_ROLE" || fail "sts identity expected role ${TASK_ROLE}, got ${IDENT}"
echo "OK: host-mode credentials + sts (${IDENT})"

# Task without taskRoleArn: no credential env
FAMILY_NOROLE="awsbox-ecs-hc-nr-${TS}"
aws ecs register-task-definition \
	--family "$FAMILY_NOROLE" \
	--requires-compatibilities EC2 \
	--network-mode host \
	--container-definitions "$CDEFS" \
	>/dev/null
NOROLE_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_NOROLE" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$NOROLE_ARN")
for _ in $(seq 1 60); do
	STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$NOROLE_ARN" --query 'tasks[0].lastStatus' --output text)"
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
[[ "$STATUS" == "RUNNING" ]] || fail "no-role task not RUNNING"
NOROLE_DOCKER="$(docker ps --filter "label=localemu.task-arn=${NOROLE_ARN}" --format '{{.Names}}' | head -1)"
NOROLE_ENV="$(docker exec "$NOROLE_DOCKER" sh -c 'env' 2>/dev/null || true)"
if echo "$NOROLE_ENV" | grep -qE '^AWS_CONTAINER_CREDENTIALS_(FULL|RELATIVE)_URI='; then
	fail "task without taskRoleArn must not set credentials URI"
fi
echo "OK: no taskRoleArn → no credentials env"

# Host-mode must not request NET_ADMIN (that path installs host iptables DNAT).
CAPS="$(docker inspect "$DOCKER_NAME" --format '{{json .HostConfig.CapAdd}}')"
if echo "$CAPS" | grep -qi NET_ADMIN; then
	fail "host-mode task must not CapAdd NET_ADMIN (got ${CAPS})"
fi
echo "OK: no NET_ADMIN on host-mode task (host iptables untouched)"

echo "OK: ecs-host-creds"
