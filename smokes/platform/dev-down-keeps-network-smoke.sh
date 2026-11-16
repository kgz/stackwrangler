#!/usr/bin/env bash
# #753: in --dev, down keeps the compose network so a bridge-mode ECS task (attached to
# <project>_default) can be resumed by up --dev. Same network ID before and after.
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
CLUSTER="sw753-${TS}"
FAMILY="sw753-${TS}"
TASK_ARN=""
MODE_BAK=test
[[ -f "$ROOT/.awsbox/mode" ]] && MODE_BAK="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"

fail() { echo "FAIL: $*" >&2; exit 1; }
aws() { command aws --endpoint-url "$EP" --region "$REGION" --cli-connect-timeout 10 --cli-read-timeout 60 "$@"; }

cleanup() {
	[[ -n "$TASK_ARN" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	printf '%s\n' "$MODE_BAK" >"$ROOT/.awsbox/mode"
}
trap cleanup EXIT

localstack() { docker ps --filter "label=com.docker.compose.project.working_dir=$ROOT" --format '{{.Names}}' | grep -E 'localstack-1$' | head -1; }
default_net_id() { # → "<name> <id>" of LocalEmu's compose default network
	docker inspect "$(localstack)" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{$v.NetworkID}}{{"\n"}}{{end}}' | grep '_default ' | head -1
}

"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
aws ecs register-task-definition --family "$FAMILY" --requires-compatibilities EC2 --network-mode bridge \
	--container-definitions '[{"name":"web","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memoryReservation":32,"portMappings":[{"containerPort":80,"hostPort":18753}]}]' >/dev/null
TASK_ARN="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" --launch-type EC2 --query 'tasks[0].taskArn' --output text)"
[[ "$TASK_ARN" == arn:* ]] || fail "RunTask returned no task"
for _ in $(seq 1 60); do [[ -n "$(docker ps -q --filter "label=localemu.task-arn=$TASK_ARN")" ]] && break; sleep 1; done
[[ -n "$(docker ps -q --filter "label=localemu.task-arn=$TASK_ARN")" ]] || fail "bridge task never started"
before="$(default_net_id)"
[[ -n "$before" ]] || fail "LocalEmu not on a <project>_default network"

"$ROOT/bin/stackwrangler" down
docker network inspect "${before%% *}" >/dev/null 2>&1 || fail "dev down removed ${before%% *}"
"$ROOT/bin/stackwrangler" up --dev
after="$(default_net_id)"
[[ "$after" == "$before" ]] || fail "compose network changed: '$before' → '$after'"

for _ in $(seq 1 60); do [[ -n "$(docker ps -q --filter "label=localemu.task-arn=$TASK_ARN")" ]] && break; sleep 1; done
[[ -n "$(docker ps -q --filter "label=localemu.task-arn=$TASK_ARN")" ]] || fail "bridge task not resumed after down → up --dev"
echo "OK: dev-down-keeps-network (#753)"
