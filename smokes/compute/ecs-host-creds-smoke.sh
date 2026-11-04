#!/usr/bin/env bash
# Host-network ECS tasks get task-role credentials on host loopback:
#   1) role → AWS_CONTAINER_CREDENTIALS_FULL_URI=127.0.0.1:<port>, no RELATIVE_URI, no DNAT,
#      AWS_ENDPOINT_URL on 127.0.0.1, creds RoleArn = task role (image without iptables)
#   2) sad: no taskRoleArn → no container-credentials env
#   3) sad: another task id → 404
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
CREDS_PORT="${AWSBOX_ECS_CREDS_PORT:-4571}"
TS="$(date +%s)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

CLUSTER="awsbox-ecs-hc-${TS}"
ROLE="awsbox-ecs-hc-task-${TS}"
TASK_ARNS=()

cleanup() {
	for arn in "${TASK_ARNS[@]:-}"; do
		[[ -n "$arn" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
	--query Role.Arn --output text)"

# Prints the credential env, the creds body, and a probe for another task's id.
PROBE='env | grep -E "^AWS_(CONTAINER_CREDENTIALS|ENDPOINT_URL)" | sort; echo "--body"; [ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ] && wget -qO- "$AWS_CONTAINER_CREDENTIALS_FULL_URI"; echo; echo "--other"; wget -qO- "http://127.0.0.1:'"$CREDS_PORT"'/v2/credentials/not-a-task" 2>&1 | head -1; sleep 120'

run_host_task() { # <family> [task role arn]
	local role_arg=()
	[[ -n "${2:-}" ]] && role_arg=(--task-role-arn "$2")
	aws ecs register-task-definition --family "$1" --network-mode host --requires-compatibilities EC2 \
		"${role_arg[@]}" --container-definitions "$(python3 -c '
import json, sys
print(json.dumps([{"name": "probe", "image": "alpine:3.20", "essential": True, "memory": 64,
                   "command": ["sh", "-c", sys.argv[1]]}]))' "$PROBE")" >/dev/null
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$1" --query 'tasks[0].taskArn' --output text
}

container_output() { # <task arn>
	local name="" out=""
	for _ in $(seq 30); do
		name="$(docker ps -a --filter "label=localemu.task-arn=$1" --format '{{.Names}}' | head -1)"
		[[ -n "$name" ]] && out="$(docker logs "$name" 2>&1)" && [[ "$out" == *"--other"* ]] && break
		sleep 2
	done
	printf '%s' "$out"
}

# --- 1) host task with a role ---
T1="$(run_host_task "awsbox-ecs-hc-role-${TS}" "$ROLE_ARN")"; TASK_ARNS+=("$T1")
OUT1="$(container_output "$T1")"
[[ "$OUT1" == *"AWS_CONTAINER_CREDENTIALS_FULL_URI=http://127.0.0.1:${CREDS_PORT}/v2/credentials/"* ]] \
	|| fail "role task missing loopback FULL_URI: $OUT1"
[[ "$OUT1" != *"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"* ]] || fail "role task still has RELATIVE_URI"
[[ "$OUT1" == *"AWS_ENDPOINT_URL=http://127.0.0.1:"* ]] || fail "host task endpoint not on loopback: $OUT1"
BODY1="$(printf '%s\n' "$OUT1" | sed -n '/^--body$/,/^--other$/p' | sed '1d;$d')"
GOT_ROLE="$(printf '%s' "$BODY1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("RoleArn",""))' 2>/dev/null || true)"
[[ "$GOT_ROLE" == "$ROLE_ARN" ]] || fail "creds RoleArn '$GOT_ROLE', want $ROLE_ARN"
if docker logs --since 5m awsl-localstack-1 2>&1 | grep -q "DNAT.*${T1##*/}"; then fail "DNAT attempted for a host task"; fi
echo "OK: host task fetches its role creds on 127.0.0.1:${CREDS_PORT}; no DNAT"

# --- 3) another task's id ---
OTHER="$(printf '%s\n' "$OUT1" | sed -n '/^--other$/{n;p}')"
[[ "$OTHER" == *"404"* ]] || fail "other task id not refused: $OTHER"
echo "OK: unknown task id → 404"

# --- 2) host task without a role ---
T2="$(run_host_task "awsbox-ecs-hc-norole-${TS}")"; TASK_ARNS+=("$T2")
OUT2="$(container_output "$T2")"
[[ "$OUT2" != *"AWS_CONTAINER_CREDENTIALS"* ]] || fail "role-less task got credentials env: $OUT2"
echo "OK: host task without a role gets no credentials env"

echo "OK: ecs host-creds smoke"
