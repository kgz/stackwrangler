#!/usr/bin/env bash
# Assert ECS bridge tasks join the subnet VPC (#230 _connect_bridge_to_vpc).
# Usage: vpc-egress-bridge-check.sh <vpc-id> <subnet-id> <security-group-id>
# Env: AWSBOX_IAM_ENDPOINT, AWSBOX_REGION (same as other smokes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

VPC_ID="${1:?vpc-id}"
SUBNET_ID="${2:?subnet-id}"
SG_ID="${3:?security-group-id}"
REGION="${AWSBOX_REGION:-us-east-1}"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
TS="$(date +%s)"
CLUSTER="awsbox-egress-bridge-${TS}"
FAMILY="awsbox-egress-bridge-${TS}"
TASK_ARN=""

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] && \
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--cpu 256 --memory 512 \
	--container-definitions "[{
		\"name\":\"sleep\",
		\"image\":\"public.ecr.aws/docker/library/alpine:3.19\",
		\"essential\":true,
		\"memory\":64,
		\"command\":[\"sleep\",\"120\"]
	}]" >/dev/null

# Pass subnet via awsvpcConfiguration so bridge attach resolves without a
# real EC2 container-instance ENI (LocalEmu forwards networkConfiguration).
TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}]}" \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || {
	echo "FAIL: bridge run-task returned no task ARN" >&2
	exit 1
}

STATUS=""
for _ in $(seq 1 60); do
	STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
		--query 'tasks[0].lastStatus' --output text)"
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$STATUS" != "RUNNING" ]]; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" >&2 || true
	echo "FAIL: bridge task not RUNNING (status=${STATUS})" >&2
	exit 1
fi

CTR=""
for _ in $(seq 1 30); do
	CTR="$(docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1 || true)"
	[[ -n "$CTR" ]] && break
	# Fallback: LocalEmu names often embed the task id suffix.
	TID="${TASK_ARN##*/}"
	CTR="$(docker ps --format '{{.Names}}' | grep -F "$TID" | head -1 || true)"
	[[ -n "$CTR" ]] && break
	sleep 1
done
[[ -n "$CTR" ]] || {
	echo "FAIL: no docker container for bridge task ${TASK_ARN}" >&2
	docker ps --format '{{.Names}}' >&2 || true
	exit 1
}

VPC_NET="localemu-vpc-${VPC_ID}"
NETS="$(docker inspect "$CTR" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
echo "bridge task ${CTR} networks: ${NETS}"

echo "$NETS" | grep -qw "$VPC_NET" || {
	echo "FAIL: bridge task not on ${VPC_NET} (nets=${NETS})" >&2
	exit 1
}

# Host-port publish stays on the default docker bridge (or compose net).
ON_DEFAULT=0
echo "$NETS" | grep -Eq '(^|[[:space:]])bridge([[:space:]]|$)' && ON_DEFAULT=1
echo "$NETS" | grep -Eq '_default([[:space:]]|$)' && ON_DEFAULT=1
[[ "$ON_DEFAULT" == "1" ]] || {
	echo "FAIL: bridge task left default/compose bridge (nets=${NETS})" >&2
	exit 1
}

# Route sync from _connect_bridge_to_vpc → _sync_subnet_routes.
RULES="$(docker run --rm --privileged --network "container:${CTR}" localemu/awsbox-rt:latest \
	iptables -t mangle -S AWSBOX-RT 2>/dev/null || true)"
echo "$RULES" | grep -q 'AWSBOX-RT' || {
	echo "FAIL: bridge task missing AWSBOX-RT mangle chain: ${RULES}" >&2
	exit 1
}

echo "ok  ECS bridge task on ${VPC_NET} with route filter (kept default bridge)"
