#!/usr/bin/env bash
# #603: RegisterTargets preserves Target.host_override (bridge dial address).
# Seeds an unreachable IP target with host_override → host.docker.internal,
# deletes the seed, re-registers via the ELBv2 API, and asserts health still
# dials the override (prove preserve-from-prev, not seed-file).
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
KEEP="${AWSBOX_ELBV2_HOST_OVERRIDE_KEEP:-0}"
HOST_PORT=18083
BAD_IP="203.0.113.83"
OVERRIDE="host.docker.internal"
SEED_FILE="/tmp/stackwrangler-elbv2-host-overrides.json"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC=""
TG=""
LS=""
HTTPD_PID=""

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	local rc=$?
	set +e
	if [[ "$KEEP" == "1" ]]; then
		echo "KEEP=1; leaving resources (exit $rc)"
		exit "$rc"
	fi
	[[ -n "$HTTPD_PID" ]] && kill "$HTTPD_PID" >/dev/null 2>&1 || true
	[[ -n "$LS" ]] && docker exec "$LS" rm -f "$SEED_FILE" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	exit "$rc"
}
trap cleanup EXIT

LS="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/stackwrangler up)"

echo "==> host TCP listener on :${HOST_PORT}"
python3 - "$HOST_PORT" <<'PY' &
import socket, sys
port = int(sys.argv[1])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(16)
while True:
    conn, _addr = srv.accept()
    conn.close()
PY
HTTPD_PID=$!
sleep 0.3
kill -0 "$HTTPD_PID" || fail "host listener failed to start"

echo "==> vpc + ip target group"
VPC="$(aws ec2 create-vpc --cidr-block 10.216.0.0/16 --query 'Vpc.VpcId' --output text)"
TG="$(aws elbv2 create-target-group \
	--name "ho${TS}" \
	--protocol TCP \
	--port "$HOST_PORT" \
	--vpc-id "$VPC" \
	--target-type ip \
	--health-check-protocol TCP \
	--health-check-port traffic-port \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"

SEED_KEY="${TG}|${BAD_IP}:${HOST_PORT}"

echo "==> register unreachable IP without override (expect not healthy)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${BAD_IP},Port=${HOST_PORT}" >/dev/null
sleep 2
STATE="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
	--query "TargetHealthDescriptions[0].TargetHealth.State" --output text)"
[[ "$STATE" != "healthy" ]] || fail "expected unhealthy before override, got ${STATE}"

echo "==> seed host_override=${OVERRIDE} then re-register"
docker exec -i "$LS" sh -c "printf '%s\n' '{\"$SEED_KEY\": \"$OVERRIDE\"}' > '$SEED_FILE'"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${BAD_IP},Port=${HOST_PORT}" >/dev/null

wait_state() {
	local want="$1" i state
	for i in $(seq 1 30); do
		state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
			--query "TargetHealthDescriptions[0].TargetHealth.State" --output text)"
		echo "health try=${i} state=${state} want=${want}"
		[[ "$state" == "$want" ]] && return 0
		sleep 1
	done
	fail "target state did not become ${want}"
}

wait_state healthy

echo "==> drop seed file; RegisterTargets must keep host_override from prev Target"
docker exec "$LS" rm -f "$SEED_FILE"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${BAD_IP},Port=${HOST_PORT}" >/dev/null
wait_state healthy

echo "OK: RegisterTargets preserved host_override (${OVERRIDE}); bridge dial healthy"
