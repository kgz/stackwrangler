#!/usr/bin/env bash
# #826: after a ghost service task (container gone) + LocalEmu restart with
# PERSISTENCE, the scheduler replaces until runningCount == desiredCount.
# Standalone RunTask staying STOPPED is correct (#716).
#
# Live: brings this worktree's stack up in --dev.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

TS="$(date +%s)"
CLUSTER="sw826-${TS}"
FAMILY="sw826-${TS}"
SVC="web-${TS}"
MODE_BAK=test
[[ -f "$ROOT/.awsbox/mode" ]] && MODE_BAK="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
OLD_TASK=""

fail() { echo "FAIL: $*" >&2; exit 1; }
aws() { command aws --endpoint-url "$EP" --region "$REGION" --cli-connect-timeout 10 --cli-read-timeout 60 "$@"; }

cleanup() {
	aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --desired-count 0 >/dev/null 2>&1 || true
	aws ecs delete-service --cluster "$CLUSTER" --service "$SVC" --force >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	printf '%s\n' "$MODE_BAK" >"$ROOT/.awsbox/mode"
}
trap cleanup EXIT

wait_running_tasks() {
	local want="$1" got=""
	for _ in $(seq 1 120); do
		got="$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING \
			--query 'length(taskArns)' --output text 2>/dev/null || echo 0)"
		[[ "$got" == "$want" ]] && return 0
		sleep 2
	done
	aws ecs describe-services --cluster "$CLUSTER" --services "$SVC" >&2 || true
	aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING >&2 || true
	aws ecs list-tasks --cluster "$CLUSTER" --desired-status STOPPED >&2 || true
	fail "RUNNING task count want=${want} got=${got}"
}

"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
aws ecs register-task-definition --family "$FAMILY" --requires-compatibilities EC2 --network-mode host \
	--container-definitions '[{"name":"web","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memoryReservation":32}]' \
	>/dev/null

aws ecs create-service --cluster "$CLUSTER" --service-name "$SVC" \
	--task-definition "$FAMILY" --desired-count 1 --launch-type EC2 >/dev/null
wait_running_tasks 1
OLD_TASK="$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --query 'taskArns[0]' --output text)"
[[ "$OLD_TASK" == arn:* ]] || fail "no running task arn"
echo "OK: service has 1 RUNNING task"

# Ghost the task (host reboot / prune): container gone, task still RUNNING in state.
CID="$(docker ps -a --filter "label=localemu.task-arn=${OLD_TASK}" --format '{{.ID}}' | head -1)"
[[ -n "$CID" ]] || fail "no docker container for ${OLD_TASK}"
docker rm -f "$CID" >/dev/null
echo "OK: ghosted task container ${CID}"

"$ROOT/bin/stackwrangler" down
"$ROOT/bin/stackwrangler" up --dev

wait_running_tasks 1
NEW_TASK="$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --query 'taskArns[0]' --output text)"
[[ "$NEW_TASK" == arn:* ]] || fail "no replacement task"
[[ "$NEW_TASK" != "$OLD_TASK" ]] || fail "expected a new task ARN after ghost restore (got same ${OLD_TASK})"
rc="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SVC" --query 'services[0].runningCount' --output text)"
[[ "$rc" == "1" ]] || fail "runningCount want=1 got=${rc}"
echo "OK: ecs service restore replaces stopped tasks (#826) old=${OLD_TASK##*/} new=${NEW_TASK##*/}"
