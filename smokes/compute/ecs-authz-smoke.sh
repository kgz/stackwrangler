#!/usr/bin/env bash
# Sad path: empty taskRoleArn → in-container PutObject AccessDenied via
# AWS_CONTAINER_CREDENTIALS_RELATIVE_URI (169.254.170.2 DNAT → LocalEmu).
# No host-side credential fetch — the task container's aws CLI resolves the
# relative URI itself (#154). Happy counterpart: ./smokes/compute/ecs-smoke.sh
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
CLUSTER="awsbox-ecs-authz-${TS}"
FAMILY="awsbox-ecs-authz-${TS}"
ROLE="awsbox-ecs-noperm-${TS}"
BUCKET="awsbox-ecs-authz-${TS}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
IMAGE="awsbox-ecs-authz:${TS}"
TMP="$(mktemp -d)"
TASK_ARN=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -rf "$TMP"; return 0; }
	if [[ -n "$TASK_ARN" ]]; then
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# aws-cli + iptables so the task can install DNAT in-netns without the
# alpine sidecar (private awsvpc has no egress for apk at runtime).
cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli iptables iproute2 wget
EOF
docker build -t "$IMAGE" "$TMP" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

aws s3 mb "s3://${BUCKET}" >/dev/null
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

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
	--requires-compatibilities FARGATE \
	--network-mode awsvpc \
	--cpu 256 --memory 512 \
	--task-role-arn "$ROLE_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

SUBNET="$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)"
SG="$(aws ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)"
[[ -n "$SUBNET" && "$SUBNET" != "None" && -n "$SG" && "$SG" != "None" ]] || {
	fail "need at least one subnet + security group (run ./smokes/compute/ecs-smoke.sh once)"
}
NET="awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SG}],assignPublicIp=ENABLED}"

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "$NET" \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask returned no taskArn"
TASK_ID="${TASK_ARN##*/}"
echo "TASK_ARN=${TASK_ARN}"

NAME=""
for _ in $(seq 1 90); do
	NAME="$(docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1)"
	[[ -n "$NAME" ]] && break
	sleep 1
done
[[ -n "$NAME" ]] || fail "task container not running"

# Container must use the relative URI (169.254 path), not host FULL_URI / static keys.
ENV_OUT="$(docker exec "$NAME" printenv)"
echo "$ENV_OUT" | grep -q '^AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/credentials/' \
	|| fail "missing AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: $ENV_OUT"
echo "$ENV_OUT" | grep -q '^AWS_CONTAINER_CREDENTIALS_FULL_URI=' \
	&& fail "awsvpc task should not set FULL_URI"
echo "$ENV_OUT" | grep -qE '^AWS_ACCESS_KEY_ID=' \
	&& fail "task must not get static AWS_ACCESS_KEY_ID (host-side keys)"

# Prove the relative URI answers from inside the task netns (DNAT path).
REL_URI="$(docker exec "$NAME" printenv AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)"
CREDS_BODY="$(docker exec "$NAME" wget -qO- --timeout=5 "http://169.254.170.2${REL_URI}")" \
	|| fail "in-container fetch of http://169.254.170.2${REL_URI} failed (DNAT?)"
echo "$CREDS_BODY" | grep -q "$ROLE_ARN" || fail "creds RoleArn mismatch: $CREDS_BODY"

# In-container put under the empty task role — aws resolves RELATIVE_URI via DNAT.
set +e
OUT="$(
	docker exec \
		-e AWS_DEFAULT_REGION="$REGION" \
		-e AWS_REGION="$REGION" \
		"$NAME" \
		aws s3api put-object \
			--bucket "$BUCKET" \
			--key authz-probe.txt \
			--body /etc/hosts \
			2>&1
)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
	fail "put succeeded; expected AccessDenied under empty task role"$'\n'"$OUT"
fi
if ! echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny'; then
	fail "expected AccessDenied from in-container aws; got:"$'\n'"$OUT"
fi

set +e
HEAD="$(aws s3api head-object --bucket "$BUCKET" --key authz-probe.txt 2>&1)"
HEAD_RC=$?
set -e
if [[ "$HEAD_RC" -eq 0 ]]; then
	fail "object written despite deny"
fi

echo "OK: in-container aws s3api put-object under empty taskRoleArn → AccessDenied (${FAMILY})"
echo "$OUT" | head -2
