#!/usr/bin/env bash
# #705: LocalEmu restart + PERSISTENCE=1 recreate keep the published host port.
#
# Requires an already-up stackwrangler compose project for this worktree.
# Recreates only the localstack service with PERSISTENCE=1 and a unique state volume.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
ID="awsbox-rds-persist-${TS}"
USER="awsbox"
PASS="AwsboxRds1!"
DB="awsbox"
HOST_PORT=$((15000 + (TS % 1000)))
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"
OVERRIDE="${TMPDIR:-/tmp}/awsbox-rds-persist-override-${TS}.yml"
STATE_VOL="awsl-rds-persist-${TS}"
PROJECT="$(basename "$ROOT")"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" -f "$OVERRIDE")
BASE_COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

wait_localemu() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (http ${code:-none})" >&2
	return 1
}

restore_default_localstack() {
	# Drop PERSISTENCE=1 / state-volume override so the shared stack is left
	# as compose defaults (PERSISTENCE=0).
	rm -f "$OVERRIDE"
	"${BASE_COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	wait_localemu >/dev/null 2>&1 || true
	docker volume rm "$STATE_VOL" >/dev/null 2>&1 || true
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$ID" --skip-final-snapshot >/dev/null 2>&1 || true
	docker rm -f "localemu-rds-${ID}" >/dev/null 2>&1 || true
	restore_default_localstack
}
trap cleanup EXIT

command -v psql >/dev/null || {
	echo "FAIL: psql required" >&2
	exit 1
}

# Unique volume name so prior smoke/debug state cannot stall Ready on resume.
cat >"$OVERRIDE" <<YAML
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${STATE_VOL}:/var/lib/localemu
volumes:
  ${STATE_VOL}:
    name: ${STATE_VOL}
YAML

wait_endpoint_port() {
	local id="$1" want="$2"
	local port=""
	for _ in $(seq 1 90); do
		port="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
		if [[ "$port" == "$want" ]]; then
			echo "$port"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: describe Port=${port:-none} want ${want}" >&2
	return 1
}

wait_psql() {
	local port="$1"
	for _ in $(seq 1 60); do
		if PGPASSWORD="$PASS" psql -h 127.0.0.1 -p "$port" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: psql not ready on 127.0.0.1:${port}" >&2
	return 1
}

start_localstack_persist() {
	echo "start localstack (PERSISTENCE=1)"
	"${COMPOSE[@]}" up -d --no-deps localstack >/dev/null
	wait_localemu
	sleep 3
}

restart_localstack_persist() {
	# Graceful stop so PERSISTENCE flushes moto state + stops (keeps) RDS containers.
	echo "restart localstack (PERSISTENCE=1, graceful)"
	"${COMPOSE[@]}" stop localstack >/dev/null
	"${COMPOSE[@]}" up -d --no-deps localstack >/dev/null
	wait_localemu
	sleep 3
}

recreate_localstack_persist() {
	echo "recreate localstack (PERSISTENCE=1, force)"
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null
	wait_localemu
	sleep 5
}

LS_ID="$("${BASE_COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS_ID" ]] || {
	echo "FAIL: localstack not up — run ./bin/stackwrangler up first" >&2
	exit 1
}

echo "== enable PERSISTENCE=1 + unique state volume ${STATE_VOL} =="
"${BASE_COMPOSE[@]}" stop localstack >/dev/null 2>&1 || true
start_localstack_persist

echo "== create with --port ${HOST_PORT} =="
aws rds create-db-instance \
	--db-instance-identifier "$ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--port "$HOST_PORT" >/dev/null

wait_endpoint_port "$ID" "$HOST_PORT" >/dev/null
wait_psql "$HOST_PORT"
PGPASSWORD="$PASS" psql -h 127.0.0.1 -p "$HOST_PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 \
	-c "CREATE TABLE IF NOT EXISTS persist_smoke (id int PRIMARY KEY, note text); INSERT INTO persist_smoke VALUES (1, 'keep-port') ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;"

echo "== LocalEmu restart keeps host port =="
restart_localstack_persist
GOT="$(wait_endpoint_port "$ID" "$HOST_PORT")"
[[ "$GOT" == "$HOST_PORT" ]] || {
	echo "FAIL: after LocalEmu restart Port=${GOT} want ${HOST_PORT}" >&2
	exit 1
}
wait_psql "$HOST_PORT"
NOTE="$(PGPASSWORD="$PASS" psql -h 127.0.0.1 -p "$HOST_PORT" -U "$USER" -d "$DB" -Atc "SELECT note FROM persist_smoke WHERE id = 1")"
[[ "$NOTE" == "keep-port" ]] || {
	echo "FAIL: data missing after restart (note=${NOTE})" >&2
	exit 1
}
echo "OK: LocalEmu restart kept ${HOST_PORT}"

echo "== PERSISTENCE recreate keeps host port (container removed, volume + meta kept) =="
docker volume inspect "localemu-rds-${ID}-data" >/dev/null
docker rm -f "localemu-rds-${ID}" >/dev/null
recreate_localstack_persist
for _ in $(seq 1 90); do
	if docker inspect "localemu-rds-${ID}" >/dev/null 2>&1; then
		break
	fi
	sleep 2
done
docker inspect "localemu-rds-${ID}" >/dev/null
GOT="$(wait_endpoint_port "$ID" "$HOST_PORT")"
[[ "$GOT" == "$HOST_PORT" ]] || {
	echo "FAIL: after persistence recreate Port=${GOT} want ${HOST_PORT}" >&2
	exit 1
}
wait_psql "$HOST_PORT"
NOTE="$(PGPASSWORD="$PASS" psql -h 127.0.0.1 -p "$HOST_PORT" -U "$USER" -d "$DB" -Atc "SELECT note FROM persist_smoke WHERE id = 1")"
[[ "$NOTE" == "keep-port" ]] || {
	echo "FAIL: data missing after recreate (note=${NOTE})" >&2
	exit 1
}
echo "OK: PERSISTENCE recreate kept ${HOST_PORT}"

echo "OK: rds host-port restart+persist ${ID}@${HOST_PORT}"
