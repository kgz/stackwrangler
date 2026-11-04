#!/usr/bin/env bash
# #201: ECS task definition fidelity —
#   1) secrets valueFrom (Secrets Manager JSON key + SSM) via execution role
#   2) execution role lacking GetSecretValue → ResourceInitializationError / STOPPED
#   3) host networkMode + portMappings starts and listens on host port
#   4) failed container create → STOPPED + stoppedReason
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

CLUSTER="awsbox-ecs-td-${TS}"
EXEC_ROLE="awsbox-ecs-exec-${TS}"
DENY_ROLE="awsbox-ecs-exec-deny-${TS}"
SECRET_NAME="awsbox-ecs-td-${TS}"
PARAM_NAME="/ecs-td/${TS}/token"
HOST_PORT=""
TASK_ARNS=()

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	for arn in "${TASK_ARNS[@]:-}"; do
		aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$EXEC_ROLE" --policy-name secrets-read >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$EXEC_ROLE" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$DENY_ROLE" --policy-name deny-secrets >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$DENY_ROLE" >/dev/null 2>&1 || true
	[[ -n "${SECRET_ARN:-}" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws ssm delete-parameter --name "$PARAM_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ALLOW_POLICY=$(cat <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":"*"},
  {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],"Resource":"*"}
]}
EOF
)

aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
EXEC_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name secrets-read --policy-document "$ALLOW_POLICY" >/dev/null

aws iam create-role --role-name "$DENY_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
DENY_ARN="$(aws iam get-role --role-name "$DENY_ROLE" --query 'Role.Arn' --output text)"
DENY_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"secretsmanager:GetSecretValue","Resource":"*"}]}'
aws iam put-role-policy --role-name "$DENY_ROLE" --policy-name deny-secrets --policy-document "$DENY_POLICY" >/dev/null

SECRET_ARN="$(
	aws secretsmanager create-secret \
		--name "$SECRET_NAME" \
		--secret-string '{"db_password":"s3cret-from-asm","other":"x"}' \
		--query 'ARN' --output text
)"
aws ssm put-parameter --name "$PARAM_NAME" --type String --value "ssm-token-${TS}" >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

# --- 1) secrets happy path ---
FAMILY_SECRETS="awsbox-ecs-secrets-${TS}"
# valueFrom with JSON key: ARN:json-key::
SECRET_VF="${SECRET_ARN}:db_password::"
CDEFS_SECRETS=$(cat <<EOF
[{
  "name": "probe",
  "image": "alpine:3.20",
  "essential": true,
  "memory": 128,
  "command": ["sh", "-c", "test \"\$DB_PASSWORD\" = 's3cret-from-asm' && test \"\$SSM_TOKEN\" = 'ssm-token-${TS}' && sleep 30"],
  "secrets": [
    {"name": "DB_PASSWORD", "valueFrom": "${SECRET_VF}"},
    {"name": "SSM_TOKEN", "valueFrom": "${PARAM_NAME}"}
  ]
}]
EOF
)

aws ecs register-task-definition \
	--family "$FAMILY_SECRETS" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--execution-role-arn "$EXEC_ARN" \
	--container-definitions "$CDEFS_SECRETS" \
	>/dev/null

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_SECRETS" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$TASK_ARN")
echo "SECRETS_TASK=${TASK_ARN}"

STATUS=""
for _ in $(seq 1 60); do
	STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)"
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$STATUS" != "RUNNING" ]]; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" >&2
	echo "FAIL: secrets task not RUNNING (status=${STATUS})" >&2
	exit 1
fi
echo "OK: secrets injected (ASM json-key + SSM) → RUNNING"

# --- 2) execution role deny → ResourceInitializationError ---
FAMILY_DENY="awsbox-ecs-secrets-deny-${TS}"
aws ecs register-task-definition \
	--family "$FAMILY_DENY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--execution-role-arn "$DENY_ARN" \
	--container-definitions "$CDEFS_SECRETS" \
	>/dev/null

DENY_TASK="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_DENY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$DENY_TASK")

DENY_STATUS=""
DENY_REASON=""
for _ in $(seq 1 30); do
	read -r DENY_STATUS DENY_REASON < <(
		aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$DENY_TASK" --output json \
			| python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; print(t.get("lastStatus",""), (t.get("stoppedReason") or "").replace("\n"," "))'
	)
	[[ "$DENY_STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$DENY_STATUS" != "STOPPED" ]]; then
	echo "FAIL: deny secrets task expected STOPPED, got ${DENY_STATUS}" >&2
	exit 1
fi
if ! echo "$DENY_REASON" | grep -qiE 'ResourceInitializationError|AccessDenied|not authorized|unable to retrieve secret'; then
	echo "FAIL: expected ResourceInitializationError in stoppedReason, got: ${DENY_REASON}" >&2
	exit 1
fi
echo "OK: execution role without GetSecretValue → STOPPED (${DENY_REASON:0:80}…)"

# --- 3) host mode + portMappings ---
FAMILY_HOST="awsbox-ecs-host-${TS}"
# Pick a free high port on the host
HOST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
CDEFS_HOST=$(cat <<EOF
[{
  "name": "web",
  "image": "hashicorp/http-echo:1.0",
  "essential": true,
  "memory": 128,
  "command": ["-listen", ":${HOST_PORT}", "-text", "awsbox-host-ok"],
  "portMappings": [
    {"containerPort": ${HOST_PORT}, "hostPort": ${HOST_PORT}, "protocol": "tcp"}
  ]
}]
EOF
)

aws ecs register-task-definition \
	--family "$FAMILY_HOST" \
	--requires-compatibilities EC2 \
	--network-mode host \
	--container-definitions "$CDEFS_HOST" \
	>/dev/null

HOST_TASK="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_HOST" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$HOST_TASK")

HOST_STATUS=""
for _ in $(seq 1 60); do
	HOST_STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$HOST_TASK" --query 'tasks[0].lastStatus' --output text)"
	[[ "$HOST_STATUS" == "RUNNING" || "$HOST_STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$HOST_STATUS" != "RUNNING" ]]; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$HOST_TASK" >&2
	echo "FAIL: host-mode task not RUNNING (status=${HOST_STATUS})" >&2
	exit 1
fi

BODY=""
for _ in $(seq 1 30); do
	BODY="$(curl -sf -m 2 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)"
	[[ "$BODY" == *"awsbox-host-ok"* ]] && break
	sleep 1
done
if [[ "$BODY" != *"awsbox-host-ok"* ]]; then
	echo "FAIL: host-mode task not listening on :${HOST_PORT}" >&2
	exit 1
fi
echo "OK: host networkMode + portMappings listens on :${HOST_PORT}"

# --- 4) failed create → STOPPED + stoppedReason ---
FAMILY_FAIL="awsbox-ecs-fail-${TS}"
# Invalid image forces pull/create failure
aws ecs register-task-definition \
	--family "$FAMILY_FAIL" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--container-definitions '[{"name":"boom","image":"awsbox.invalid/no-such-image:never","essential":true,"memory":64,"command":["true"]}]' \
	>/dev/null

FAIL_TASK="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_FAIL" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$FAIL_TASK")

FAIL_JSON="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$FAIL_TASK" --output json)"
FAIL_STATUS="$(echo "$FAIL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][0].get("lastStatus",""))')"
FAIL_REASON="$(echo "$FAIL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][0].get("stoppedReason") or "")')"

if [[ "$FAIL_STATUS" != "STOPPED" ]]; then
	# give pull a moment then re-check
	for _ in $(seq 1 20); do
		FAIL_JSON="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$FAIL_TASK" --output json)"
		FAIL_STATUS="$(echo "$FAIL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][0].get("lastStatus",""))')"
		FAIL_REASON="$(echo "$FAIL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][0].get("stoppedReason") or "")')"
		[[ "$FAIL_STATUS" == "STOPPED" ]] && break
		sleep 1
	done
fi
if [[ "$FAIL_STATUS" != "STOPPED" ]]; then
	echo "FAIL: bad-image task expected STOPPED, got ${FAIL_STATUS}" >&2
	echo "$FAIL_JSON" >&2
	exit 1
fi
if [[ -z "$FAIL_REASON" ]]; then
	echo "FAIL: bad-image task STOPPED but missing stoppedReason" >&2
	exit 1
fi
echo "OK: failed start → STOPPED (${FAIL_REASON:0:80}…)"

echo "OK: ecs taskdef smoke (secrets / deny / host / failed-start)"
