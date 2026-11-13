#!/usr/bin/env bash
# #716: after LocalEmu restarts with PERSISTENCE=1, ghost ECS tasks
# (RUNNING/DEACTIVATING, no Docker container) must be STOPPED and release
# instance resources so a new host-mode task can place. Stopped-but-present
# containers are resumed.
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
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
STATE_DIR="${ROOT}/.awsbox/ecs-persist-716-state"
OVERRIDE="${ROOT}/.awsbox/ecs-persist-716.override.yml"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

COMPOSE=(docker compose -f "${ROOT}/docker-compose.yml" -f "${OVERRIDE}")
CLUSTER="awsbox-ecs-persist-${TS}"
FAMILY="awsbox-ecs-persist-${TS}"
HOST_PORT=""
TASK_ARNS=()

localemu_cid() {
	docker ps --format '{{.Names}}' | grep -E 'localstack-1$' | head -1
}

wait_localemu() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (${code:-empty})" >&2
	return 1
}

task_container() {
	local arn="$1"
	local short="${arn##*/}"
	docker ps -a --filter "label=localemu.service=ecs" --format '{{.ID}} {{.Label "localemu.task-arn"}}' \
		| awk -v s="$short" 'index($0, s) { print $1; exit }'
}

wait_status() {
	local arn="$1"
	local want="$2"
	local status=""
	for _ in $(seq 1 90); do
		status="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].lastStatus' --output text 2>/dev/null || true)"
		[[ "$status" == "$want" ]] && {
			echo "$status"
			return 0
		}
		sleep 2
	done
	echo "$status"
	return 1
}

enable_persistence() {
	mkdir -p "$STATE_DIR"
	cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${STATE_DIR}:/var/lib/localemu
EOF
	"${COMPOSE[@]}" up -d --no-deps --force-recreate localstack >/dev/null
	wait_localemu
}

restart_localemu() {
	local cid
	cid="$(localemu_cid)"
	[[ -n "$cid" ]] || {
		echo "FAIL: no localstack container" >&2
		exit 1
	}
	docker restart "$cid" >/dev/null
	wait_localemu
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	for arn in "${TASK_ARNS[@]:-}"; do
		aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	docker ps -aq --filter "label=localemu.cluster=${CLUSTER}" | xargs -r docker rm -f >/dev/null 2>&1 || true
	# Restore non-persistent LocalEmu for other smokes on this stack.
	rm -f "$OVERRIDE"
	docker compose -f "${ROOT}/docker-compose.yml" up -d --no-deps --force-recreate localstack >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== #716 enable PERSISTENCE=1 =="
enable_persistence
cid="$(localemu_cid)"
pers="$(docker exec "$cid" sh -c 'echo $PERSISTENCE')"
[[ "$pers" == "1" ]] || {
	echo "FAIL: PERSISTENCE=$pers (want 1)" >&2
	exit 1
}

HOST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS=$(cat <<EOF
[{
  "name": "probe",
  "image": "hashicorp/http-echo:1.0",
  "essential": true,
  "memory": 768,
  "cpu": 256,
  "command": ["-listen", ":${HOST_PORT}", "-text", "persist-ok"],
  "portMappings": [
    {"containerPort": ${HOST_PORT}, "hostPort": ${HOST_PORT}, "protocol": "tcp"}
  ]
}]
EOF
)

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode host \
	--container-definitions "$CDEFS" \
	>/dev/null

run_one() {
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
}

# --- A) ghost: remove container, restart LocalEmu → STOPPED + free placement ---
echo "== #716 ghost task after restart =="
TASK1="$(run_one)"
TASK_ARNS+=("$TASK1")
if ! wait_status "$TASK1" RUNNING >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK1" >&2
	echo "FAIL: task1 not RUNNING" >&2
	exit 1
fi
CID1="$(task_container "$TASK1")"
[[ -n "$CID1" ]] || {
	echo "FAIL: no docker container for task1" >&2
	exit 1
}
docker rm -f "$CID1" >/dev/null
restart_localemu

DESC1="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK1" --output json)"
STATUS1="$(echo "$DESC1" | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"]; print(t[0].get("lastStatus","") if t else "MISSING")')"
REASON1="$(echo "$DESC1" | python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"]; print((t[0].get("stoppedReason") or "") if t else "")')"
if [[ "$STATUS1" != "STOPPED" ]]; then
	echo "FAIL: ghost task expected STOPPED after restart, got ${STATUS1}" >&2
	echo "$DESC1" >&2
	exit 1
fi
if [[ "$REASON1" != *"Task container not restored"* ]]; then
	echo "FAIL: expected stoppedReason 'Task container not restored', got '${REASON1}'" >&2
	exit 1
fi
echo "OK: ghost task STOPPED (${REASON1})"

TASK2="$(run_one)"
TASK_ARNS+=("$TASK2")
if [[ -z "$TASK2" || "$TASK2" == "None" ]]; then
	echo "FAIL: run-task placed nothing after ghost restart" >&2
	exit 1
fi
if ! wait_status "$TASK2" RUNNING >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK2" >&2
	echo "FAIL: replacement task not RUNNING" >&2
	exit 1
fi
BODY=""
for _ in $(seq 1 30); do
	BODY="$(curl -sf -m 2 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)"
	[[ "$BODY" == *"persist-ok"* ]] && break
	sleep 1
done
if [[ "$BODY" != *"persist-ok"* ]]; then
	echo "FAIL: replacement task not listening on :${HOST_PORT}" >&2
	exit 1
fi
echo "OK: run-task places again after ghost restart"

# --- B) stop container on disk, restart → resume ---
echo "== #716 resume stopped container after restart =="
CID2="$(task_container "$TASK2")"
[[ -n "$CID2" ]] || {
	echo "FAIL: no docker container for task2" >&2
	exit 1
}
# Leave the container stopped (persistence shutdown does this). Do not rm.
docker stop "$CID2" >/dev/null
restart_localemu
if ! wait_status "$TASK2" RUNNING >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK2" >&2
	echo "FAIL: task2 not RUNNING after resume restart" >&2
	exit 1
fi
BODY=""
for _ in $(seq 1 30); do
	BODY="$(curl -sf -m 2 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)"
	[[ "$BODY" == *"persist-ok"* ]] && break
	sleep 1
done
if [[ "$BODY" != *"persist-ok"* ]]; then
	echo "FAIL: resumed task not listening on :${HOST_PORT}" >&2
	exit 1
fi
echo "OK: stopped container resumed after restart"

# --- C) stop-task must finish STOPPED (not stick in DEACTIVATING) ---
echo "== #716 stop-task finishes STOPPED =="
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK2" --reason "smoke-stop" >/dev/null
if ! wait_status "$TASK2" STOPPED >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK2" >&2
	echo "FAIL: task2 not STOPPED after stop-task" >&2
	exit 1
fi

TASK3="$(run_one)"
TASK_ARNS+=("$TASK3")
if ! wait_status "$TASK3" RUNNING >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK3" >&2
	echo "FAIL: task3 not RUNNING" >&2
	exit 1
fi
CID3="$(task_container "$TASK3")"
docker rm -f "$CID3" >/dev/null
# Describe once so ManagedState can tick toward DEACTIVATING, then stop.
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK3" >/dev/null || true
aws ecs stop-task --cluster "$CLUSTER" --task "$TASK3" --reason "smoke-stop-ghost" >/dev/null
STOP_JSON="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK3" --output json)"
STOP_STATUS="$(echo "$STOP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tasks"][0].get("lastStatus",""))')"
if [[ "$STOP_STATUS" != "STOPPED" ]]; then
	echo "FAIL: ghost stop-task expected STOPPED, got ${STOP_STATUS}" >&2
	echo "$STOP_JSON" >&2
	exit 1
fi

TASK4="$(run_one)"
TASK_ARNS+=("$TASK4")
if [[ -z "$TASK4" || "$TASK4" == "None" ]]; then
	echo "FAIL: run-task placed nothing after ghost stop-task" >&2
	exit 1
fi
if ! wait_status "$TASK4" RUNNING >/dev/null; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK4" >&2
	echo "FAIL: task4 not RUNNING after ghost stop" >&2
	exit 1
fi
echo "OK: ghost stop-task finishes STOPPED and frees placement"

echo "OK: ecs persist reconcile smoke (#716)"
