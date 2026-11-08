#!/usr/bin/env bash
# Call-log attribution for ECS task-role session + CLI profile IAM user (#602).
# Depends on CloudTrail-lite hooks/helpers from #194 / PR #597
# (GET /_awsl/calls + smokes/lib/api-call-log.sh).
#
# ECS: bridge task with taskRoleArn → secretsmanager:GetSecretValue
#      attributed to session name ecs-task-<taskId[:32]>.
# CLI: named AWS profile for an IAM user → same action attributed to user/<name>.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

if [[ ! -f "$ROOT/smokes/lib/api-call-log.sh" ]]; then
	echo "FAIL: smokes/lib/api-call-log.sh missing (needs #194 / PR #597 merged or present)" >&2
	exit 1
fi
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/api-call-log.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${AWSBOX_CALLLOG_KEEP:-0}"
CLUSTER="awsbox-calllog-ecs-${TS}"
FAMILY="awsbox-calllog-ecs-${TS}"
ROLE="awsbox-calllog-ecs-role-${TS}"
USER="awsbox-calllog-cli-${TS}"
SECRET_NAME="awsbox/calllog-ecs-cli-${TS}"
PROFILE="calllog-cli-${TS}"
IMAGE="awsbox-calllog-ecs:${TS}"
TMP="$(mktemp -d)"
TASK_ARN=""
SECRET_ARN=""
USER_KEY=""

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$TASK_ARN" ]]; then
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$SECRET_ARN" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name sm-read >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	if [[ -n "$USER_KEY" ]]; then
		aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY" >/dev/null 2>&1 || true
	fi
	aws iam delete-user-policy --user-name "$USER" --policy-name sm-read >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

curl -sf --max-time 3 "${EP}/_awsl/calls" >/dev/null || {
	fail "GET /_awsl/calls not reachable at ${EP} (needs #194 LocalEmu hooks)"
}

# Bridge + task role: RELATIVE_URI + sidecar DNAT (host mode pins :4566 and
# breaks when LocalEmu is published on a distinct host port).
cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli wget
EOF
docker build -t "$IMAGE" "$TMP" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE_ARN="$(
	aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
		--query 'Role.Arn' --output text
)"
aws iam put-role-policy --role-name "$ROLE" --policy-name sm-read --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"*"}]}
EOF
)"

SECRET_ARN="$(
	aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "calllog-ecs-cli-${TS}" \
		--query 'ARN' --output text
)"

aws iam create-user --user-name "$USER" >/dev/null
aws iam put-user-policy --user-name "$USER" --policy-name sm-read --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"*"}]}
EOF
)"
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
USER_KEY="$(printf '%s' "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
USER_SECRET="$(printf '%s' "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

# Bridge task: sleep so we can docker-exec under the task-role RELATIVE_URI.
CDEFS="$(IMAGE="$IMAGE" python3 -c '
import json, os
print(json.dumps([{
  "name": "probe",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 128,
  "command": ["sleep", "180"],
}]))
')"
aws ecs register-task-definition \
	--family "$FAMILY" \
	--network-mode bridge \
	--requires-compatibilities EC2 \
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
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask returned no taskArn"
TASK_ID="${TASK_ARN##*/}"
ECS_WORKLOAD="ecs-task-${TASK_ID:0:32}"
echo "TASK_ARN=${TASK_ARN} workload=${ECS_WORKLOAD}"

NAME=""
for _ in $(seq 1 90); do
	NAME="$(docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1 || true)"
	if [[ -z "$NAME" ]]; then
		# Fallback: truncated task-id appears in the LocalEmu container name.
		NAME="$(docker ps --format '{{.Names}}' | grep -F "localemu-ecs-" | grep -F "${TASK_ID:0:8}" | head -1 || true)"
	fi
	[[ -n "$NAME" ]] && break
	sleep 1
done
[[ -n "$NAME" ]] || fail "task container not running (task=${TASK_ARN})"

ENV_OUT="$(docker exec "$NAME" printenv)"
echo "$ENV_OUT" | grep -q '^AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/credentials/' \
	|| fail "missing AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: $ENV_OUT"
echo "$ENV_OUT" | grep -qE '^AWS_ENDPOINT_URL=http://' \
	|| fail "missing AWS_ENDPOINT_URL: $ENV_OUT"

REL_URI="$(docker exec "$NAME" printenv AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)"
CREDS_BODY="$(docker exec "$NAME" wget -qO- --timeout=5 "http://169.254.170.2${REL_URI}")" \
	|| fail "in-container fetch of http://169.254.170.2${REL_URI} failed (DNAT?)"
echo "$CREDS_BODY" | grep -q "$ROLE_ARN" || fail "creds RoleArn mismatch: $CREDS_BODY"

# --- ECS task role session ---
api_call_log_clear
set +e
ECS_OUT="$(
	docker exec \
		-e AWS_DEFAULT_REGION="$REGION" \
		-e AWS_REGION="$REGION" \
		"$NAME" \
		aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" 2>&1
)"
ECS_RC=$?
set -e
[[ "$ECS_RC" -eq 0 ]] || fail "ECS GetSecretValue failed: $ECS_OUT"
echo "$ECS_OUT" | grep -q "calllog-ecs-cli-${TS}" || fail "ECS secret payload missing: $ECS_OUT"

api_call_log_assert_exactly "$ECS_WORKLOAD" 'secretsmanager:GetSecretValue'
api_call_log_assert_no_calls "$ECS_WORKLOAD" 's3:*'
echo "OK: ECS task role session attributed as workload ${ECS_WORKLOAD}"

# --- CLI named profile (IAM user principal) ---
CLI_WORKLOAD="user/${USER}"
mkdir -p "$TMP/aws"
cat >"$TMP/aws/credentials" <<EOF
[${PROFILE}]
aws_access_key_id = ${USER_KEY}
aws_secret_access_key = ${USER_SECRET}
EOF
cat >"$TMP/aws/config" <<EOF
[profile ${PROFILE}]
region = ${REGION}
EOF

api_call_log_clear
# local-emu-env nulls profile files; restore for this principal only.
(
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	export AWS_CONFIG_FILE="$TMP/aws/config"
	export AWS_SHARED_CREDENTIALS_FILE="$TMP/aws/credentials"
	export AWS_PROFILE="$PROFILE"
	command aws --endpoint-url "$EP" --region "$REGION" \
		secretsmanager get-secret-value --secret-id "$SECRET_ARN" >/dev/null
)

api_call_log_assert_exactly "$CLI_WORKLOAD" 'secretsmanager:GetSecretValue'
api_call_log_assert_no_calls "$CLI_WORKLOAD" 's3:*'
api_call_log_assert_no_calls "$ECS_WORKLOAD" 'secretsmanager:*'
echo "OK: CLI profile principal attributed as workload ${CLI_WORKLOAD}"

echo "OK: api-call-log ECS/CLI smoke (#602)"
