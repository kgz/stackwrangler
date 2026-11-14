#!/usr/bin/env bash
# #715: memoryReservation is soft (mem_reservation), not a hard mem_limit.
# EC2 task with only memoryReservation:64 that allocates ~200MB must stay
# running (not exit 137). memory → Docker Memory; memoryReservation →
# MemoryReservation; both set → both HostConfig fields.
# Absorbs #707: RegisterTaskDefinition accepts memoryReservation-only on EC2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

CLUSTER="awsbox-ecs-mem-${TS}"
TASK_ARNS=()

cleanup() {
	for arn in "${TASK_ARNS[@]:-}"; do
		[[ -n "$arn" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

ALLOC_CMD='python3 -c "b=bytearray(200*1024*1024); import time; time.sleep(120)"'

register_and_run() { # <family> <cdef-json>
	aws ecs register-task-definition --family "$1" --network-mode bridge \
		--requires-compatibilities EC2 \
		--container-definitions "$2" >/dev/null
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$1" \
		--query 'tasks[0].taskArn' --output text
}

wait_docker() { # <task arn> → docker name
	local name=""
	for _ in $(seq 60); do
		name="$(docker ps -a --filter "label=localemu.task-arn=$1" --format '{{.Names}}' | head -1)"
		if [[ -n "$name" ]] && docker inspect "$name" >/dev/null 2>&1; then
			printf '%s' "$name"
			return 0
		fi
		sleep 1
	done
	return 1
}

inspect_mem() { # <docker name> → Memory / MemoryReservation (bytes)
	local name="$1" out=""
	for _ in $(seq 10); do
		if out="$(docker inspect "$name" --format '{{.HostConfig.Memory}} {{.HostConfig.MemoryReservation}}' 2>/dev/null)"; then
			printf '%s' "$out"
			return 0
		fi
		sleep 1
	done
	return 1
}

# --- soft only (AC): reservation 64 MiB, allocate 200 MiB → must stay running ---
SOFT_CDEF="$(python3 -c '
import json, sys
print(json.dumps([{
  "name": "burst",
  "image": "python:3.12-alpine",
  "essential": True,
  "memoryReservation": 64,
  "command": ["sh", "-c", sys.argv[1]],
}]))' "$ALLOC_CMD")"
T_SOFT="$(register_and_run "awsbox-ecs-mem-soft-${TS}" "$SOFT_CDEF")"
TASK_ARNS+=("$T_SOFT")
D_SOFT="$(wait_docker "$T_SOFT")" || fail "soft-only container never appeared"
read -r MEM HARD_RES <<<"$(inspect_mem "$D_SOFT")" || fail "soft-only inspect vanished"
[[ "$MEM" == "0" ]] || fail "soft-only set hard Memory=$MEM (want 0)"
[[ "$HARD_RES" == "67108864" ]] || fail "soft-only MemoryReservation=$HARD_RES (want 67108864)"

for _ in $(seq 30); do
	STATUS="$(docker inspect "$D_SOFT" --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}')"
	case "$STATUS" in
		"running "*" false") break ;;
		"exited 137 "*|"exited "*" true")
			fail "soft-only OOM-killed (status=$STATUS); memoryReservation was treated as hard"
			;;
		"exited "*)
			fail "soft-only exited early: $STATUS"
			;;
	esac
	sleep 2
done
STATUS="$(docker inspect "$D_SOFT" --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}')"
[[ "$STATUS" == running* ]] || fail "soft-only not running after allocate: $STATUS"
echo "OK: memoryReservation-only (64) survives ~200MB allocate (not exit 137)"

aws ecs stop-task --cluster "$CLUSTER" --task "$T_SOFT" >/dev/null 2>&1 || true
docker rm -f "$D_SOFT" >/dev/null 2>&1 || true

# --- both: HostConfig gets hard Memory + soft MemoryReservation ---
BOTH_CDEF="$(python3 -c '
import json, sys
print(json.dumps([{
  "name": "capped",
  "image": "python:3.12-alpine",
  "essential": True,
  "memory": 128,
  "memoryReservation": 64,
  "command": ["sleep", "60"],
}]))')"
T_BOTH="$(register_and_run "awsbox-ecs-mem-both-${TS}" "$BOTH_CDEF")"
TASK_ARNS+=("$T_BOTH")
D_BOTH="$(wait_docker "$T_BOTH")" || fail "both-limits container never appeared"
read -r MEM2 RES2 <<<"$(inspect_mem "$D_BOTH")" || fail "both-limits inspect vanished"
[[ "$MEM2" == "134217728" ]] || fail "both: Memory=$MEM2 (want 134217728)"
[[ "$RES2" == "67108864" ]] || fail "both: MemoryReservation=$RES2 (want 67108864)"
echo "OK: memory=128 + memoryReservation=64 both applied on HostConfig"

echo "OK: ecs soft-memory smoke (#715)"
