#!/usr/bin/env bash
# #254: bridge taskRoleArn on an image without iptables still fetches
# AWS_CONTAINER_CREDENTIALS_RELATIVE_URI via the alpine netns sidecar DNAT
# (same path as awsvpc #154). No host iptables mutation.
# Sad: empty task role → in-container PutObject AccessDenied.
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
CLUSTER="awsbox-ecs-bridge-nipt-${TS}"
FAMILY="awsbox-ecs-bridge-nipt-${TS}"
ROLE="awsbox-ecs-bridge-nipt-${TS}"
BUCKET="awsbox-ecs-bridge-nipt-${TS}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
IMAGE="awsbox-ecs-bridge-nipt:${TS}"
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

# Deliberately no iptables / iproute2 — DNAT must use awsbox-rt sidecar.
cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli wget
EOF
docker build -t "$IMAGE" "$TMP" >/dev/null

# Prove the image really lacks iptables (else this smoke is a false positive).
docker run --rm --entrypoint sh "$IMAGE" -c 'command -v iptables' >/dev/null 2>&1 \
	&& fail "test image unexpectedly has iptables"

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
	--requires-compatibilities EC2 \
	--network-mode bridge \
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
echo "TASK_ARN=${TASK_ARN}"

NAME=""
for _ in $(seq 1 90); do
	NAME="$(docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1)"
	[[ -n "$NAME" ]] && break
	sleep 1
done
[[ -n "$NAME" ]] || fail "task container not running"

ENV_OUT="$(docker exec "$NAME" printenv)"
echo "$ENV_OUT" | grep -q '^AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/v2/credentials/' \
	|| fail "missing AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: $ENV_OUT"
echo "$ENV_OUT" | grep -q '^AWS_CONTAINER_CREDENTIALS_FULL_URI=' \
	&& fail "bridge task should not set FULL_URI (host path only)"
echo "$ENV_OUT" | grep -qE '^AWS_ACCESS_KEY_ID=' \
	&& fail "task must not get static AWS_ACCESS_KEY_ID"

REL_URI="$(docker exec "$NAME" printenv AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)"
CREDS_BODY="$(docker exec "$NAME" wget -qO- --timeout=8 "http://169.254.170.2${REL_URI}")" \
	|| fail "in-container fetch of http://169.254.170.2${REL_URI} failed (sidecar DNAT?)"
echo "$CREDS_BODY" | grep -q "$ROLE_ARN" || fail "creds RoleArn mismatch: $CREDS_BODY"

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

echo "OK: bridge + no-iptables image → sidecar DNAT → AccessDenied (${FAMILY})"
echo "$OUT" | head -2
