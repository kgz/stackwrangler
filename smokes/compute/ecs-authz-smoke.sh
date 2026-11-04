#!/usr/bin/env bash
# Sad path: ECS taskRoleArn with no S3 perms → PutObject AccessDenied.
# RunTask mints task-role session creds (LocalEmu); we assert with those keys.
# (In-container 169.254.170.2 DNAT is broken under compose — Debt if fixed upstream.)
# Happy counterpart: ./smokes/compute/ecs-smoke.sh
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
TASK_ARN=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

localemu_cid() {
	docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null \
		|| docker ps --filter "ancestor=localemu/localemu:latest" --format '{{.ID}}' | head -1
}

creds_port() {
	local cid="$1"
	docker logs "$cid" 2>&1 \
		| grep -oE 'ECS task credentials server listening on port [0-9]+' \
		| tail -1 \
		| grep -oE '[0-9]+$'
}

fetch_task_creds() {
	local cid="$1" port="$2" task_id="$3"
	docker exec "$cid" /opt/code/localemu/.venv/bin/python -c "
import json, urllib.request
print(urllib.request.urlopen(
    'http://127.0.0.1:${port}/v2/credentials/${task_id}', timeout=5
).read().decode())
"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$TASK_ARN" ]]; then
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

LEMU="$(localemu_cid)"
[[ -n "$LEMU" ]] || {
	echo "FAIL: LocalEmu container not running (docker compose up)" >&2
	exit 1
}

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

aws s3 mb "s3://${BUCKET}" >/dev/null
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

# Sleep so creds stay queryable after mint; LocalEmu ignores entryPoint.
aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities FARGATE \
	--network-mode awsvpc \
	--cpu 256 --memory 512 \
	--task-role-arn "$ROLE_ARN" \
	--container-definitions '[{"name":"probe","image":"alpine:3.20","essential":true,"memory":128,"command":["sleep","60"]}]' \
	>/dev/null

SUBNET="$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)"
SG="$(aws ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)"
[[ -n "$SUBNET" && "$SUBNET" != "None" && -n "$SG" && "$SG" != "None" ]] || {
	echo "FAIL: need at least one subnet + security group (run ./smokes/compute/ecs-smoke.sh once)" >&2
	exit 1
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
TASK_ID="${TASK_ARN##*/}"
echo "TASK_ARN=${TASK_ARN}"

# Creds server starts on first task-role mint
for _ in $(seq 1 30); do
	PORT="$(creds_port "$LEMU")"
	[[ -n "$PORT" ]] && break
	sleep 1
done
[[ -n "$PORT" ]] || {
	echo "FAIL: ECS credentials server never logged a port" >&2
	exit 1
}

CREDS=""
for _ in $(seq 1 30); do
	set +e
	CREDS="$(fetch_task_creds "$LEMU" "$PORT" "$TASK_ID" 2>/dev/null)"
	RC=$?
	set -e
	[[ "$RC" -eq 0 && -n "$CREDS" ]] && break
	sleep 1
done
[[ -n "$CREDS" ]] || {
	echo "FAIL: could not fetch task credentials for ${TASK_ID}" >&2
	exit 1
}

eval "$(echo "$CREDS" | python3 -c '
import json,sys,shlex
d=json.load(sys.stdin)
print("TASK_ROLE_ARN="+shlex.quote(d["RoleArn"]))
print("TASK_AK="+shlex.quote(d["AccessKeyId"]))
print("TASK_SK="+shlex.quote(d["SecretAccessKey"]))
print("TASK_TOK="+shlex.quote(d["Token"]))
')"

if [[ "$TASK_ROLE_ARN" != "$ROLE_ARN" ]]; then
	echo "FAIL: minted RoleArn=${TASK_ROLE_ARN} want ${ROLE_ARN}" >&2
	exit 1
fi

set +e
OUT="$(
	AWS_ACCESS_KEY_ID="$TASK_AK" AWS_SECRET_ACCESS_KEY="$TASK_SK" AWS_SESSION_TOKEN="$TASK_TOK" \
		aws s3api put-object \
			--bucket "$BUCKET" \
			--key authz-probe.txt \
			--body /etc/hosts \
			2>&1
)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
	echo "FAIL: put succeeded; expected AccessDenied under empty task role" >&2
	echo "$OUT" >&2
	exit 1
fi
if ! echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny'; then
	echo "FAIL: expected AccessDenied in output:" >&2
	echo "$OUT" >&2
	exit 1
fi

set +e
HEAD="$(aws s3api head-object --bucket "$BUCKET" --key authz-probe.txt 2>&1)"
HEAD_RC=$?
set -e
if [[ "$HEAD_RC" -eq 0 ]]; then
	echo "FAIL: object written despite deny" >&2
	exit 1
fi

echo "OK: ECS task role without s3:PutObject → AccessDenied (${FAMILY})"
echo "$OUT" | head -2
