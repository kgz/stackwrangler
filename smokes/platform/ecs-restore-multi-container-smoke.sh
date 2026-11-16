#!/usr/bin/env bash
# #747: after down → up --dev, every container of a multi-container ECS task is resumed,
# a single-container task with a fixed host port is resumed, and RunTask on a held host port
# reports RESOURCE:PORTS (not an empty success). Stopping the holder frees the port.
# Host network mode: bridge-mode tasks lose the compose network on down (separate issue).
#
# Live: brings this worktree's stack up in --dev (gate first: ./bin/batch-resource-gate.sh check --need-up).
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
CLUSTER="sw747-${TS}"
PAIR="sw747-pair-${TS}"
SOLO="sw747-solo-${TS}"
PAIR_ARN=""
SOLO_ARN=""
MODE_BAK=test
[[ -f "$ROOT/.awsbox/mode" ]] && MODE_BAK="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"

fail() { echo "FAIL: $*" >&2; exit 1; }
aws() { command aws --endpoint-url "$EP" --region "$REGION" --cli-connect-timeout 10 --cli-read-timeout 60 "$@"; }

cleanup() {
	for t in "$PAIR_ARN" "$SOLO_ARN"; do
		[[ -n "$t" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$t" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	printf '%s\n' "$MODE_BAK" >"$ROOT/.awsbox/mode"
}
trap cleanup EXIT

running_for() { # task-arn → number of running containers
	docker ps --filter "label=localemu.task-arn=$1" --format '{{.Names}}' | grep -c . || true
}

wait_running() { # task-arn want
	local n=0
	for _ in $(seq 1 90); do
		n="$(running_for "$1")"
		[[ "$n" -ge "$2" ]] && return 0
		sleep 1
	done
	fail "task $1: $n/$2 containers running"
}

"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
aws ecs register-task-definition --family "$PAIR" --requires-compatibilities EC2 --network-mode host \
	--container-definitions '[
	  {"name":"front","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memoryReservation":32,"portMappings":[{"containerPort":18747,"hostPort":18747}]},
	  {"name":"back","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memoryReservation":32}
	]' >/dev/null
aws ecs register-task-definition --family "$SOLO" --requires-compatibilities EC2 --network-mode host \
	--container-definitions '[{"name":"solo","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memoryReservation":32,"portMappings":[{"containerPort":18748,"hostPort":18748}]}]' >/dev/null

PAIR_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$PAIR" --launch-type EC2 --query 'tasks[0].taskArn' --output text)"
SOLO_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$SOLO" --launch-type EC2 --query 'tasks[0].taskArn' --output text)"
[[ "$PAIR_ARN" == arn:* && "$SOLO_ARN" == arn:* ]] || fail "RunTask returned no task ($PAIR_ARN / $SOLO_ARN)"
wait_running "$PAIR_ARN" 2
wait_running "$SOLO_ARN" 1
echo "OK: pair (2 containers) + solo running"

"$ROOT/bin/stackwrangler" down
"$ROOT/bin/stackwrangler" up --dev
wait_running "$PAIR_ARN" 2
wait_running "$SOLO_ARN" 1
echo "OK: both containers of the pair task and the solo task resumed after down → up --dev"

listed="$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING --query taskArns --output text)"
[[ "$listed" == *"$PAIR_ARN"* && "$listed" == *"$SOLO_ARN"* ]] || fail "restored tasks not listed as RUNNING: $listed"

out="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$SOLO" --launch-type EC2 --output json)"
echo "$out" | grep -q '"RESOURCE:PORTS"' || fail "RunTask on a held host port did not report RESOURCE:PORTS: $out"
echo "OK: held host port → failures RESOURCE:PORTS"

aws ecs stop-task --cluster "$CLUSTER" --task "$SOLO_ARN" >/dev/null
SOLO_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$SOLO" --launch-type EC2 --query 'tasks[0].taskArn' --output text)"
[[ "$SOLO_ARN" == arn:* ]] || fail "RunTask after stop-task placed nothing"
wait_running "$SOLO_ARN" 1
echo "OK: ecs-restore-multi-container (#747)"
