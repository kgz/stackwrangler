#!/usr/bin/env bash
# #708: host/bridge CreateService/DescribeServices and RunTask/DescribeTasks must
# omit networkConfiguration (moto used to return {}). Empty {} crashes Terraform.
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
CLUSTER="awsbox-ecs-netcfg-${TS}"
FAMILY="awsbox-ecs-netcfg-${TS}"
SVC="host-${TS}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
TASK_ARN=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$TASK_ARN" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --desired-count 0 >/dev/null 2>&1 || true
	aws ecs delete-service --cluster "$CLUSTER" --service "$SVC" --force >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

assert_net_omitted() {
	local label="$1" json="$2"
	local net
	net="$(echo "$json" | python3 -c 'import json,sys; s=json.load(sys.stdin); print("PRESENT" if "networkConfiguration" in s else "OMITTED")')"
	[[ "$net" == "OMITTED" ]] || fail "${label} still has networkConfiguration: $(echo "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("networkConfiguration"))')"
}

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

TD_JSON="$(mktemp)"
cat >"$TD_JSON" <<EOF
{
  "family": "${FAMILY}",
  "networkMode": "host",
  "requiresCompatibilities": ["EC2"],
  "containerDefinitions": [{
    "name": "web",
    "image": "public.ecr.aws/docker/library/nginx:alpine",
    "memory": 128,
    "essential": true
  }]
}
EOF
TD="$(aws ecs register-task-definition --cli-input-json "file://${TD_JSON}" --query 'taskDefinition.taskDefinitionArn' --output text)"
rm -f "$TD_JSON"

CREATE_JSON="$(aws ecs create-service --cluster "$CLUSTER" --service-name "$SVC" \
	--task-definition "$TD" --desired-count 0 --launch-type EC2 \
	--query 'service' --output json)"
assert_net_omitted "CreateService" "$CREATE_JSON"

DESC_JSON="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SVC" \
	--query 'services[0]' --output json)"
assert_net_omitted "DescribeServices" "$DESC_JSON"

RUN_JSON="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TD" \
	--launch-type EC2 --count 1 --query 'tasks[0]' --output json)"
assert_net_omitted "RunTask" "$RUN_JSON"
TASK_ARN="$(echo "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["taskArn"])')"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask did not return taskArn"

DESC_TASK="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
	--query 'tasks[0]' --output json)"
assert_net_omitted "DescribeTasks" "$DESC_TASK"

echo "OK: host/bridge ECS omits networkConfiguration (service + task)"
