#!/usr/bin/env bash
# #743: MySQL SQL row + endpoint/port survive LocalEmu PERSISTENCE=1 recreate.
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
ID="awsbox-mysql-persist-${TS}"
USER="awsbox"
PASS="AwsboxRds1!"
DB="awsbox"
HOST_PORT=$((16000 + (TS % 1000)))
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"
OVERRIDE="${TMPDIR:-/tmp}/awsbox-mysql-persist-override-${TS}.yml"
STATE_VOL="awsl-mysql-persist-${TS}"
PROJECT="$(basename "$ROOT")"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" -f "$OVERRIDE")
BASE_COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_MAX_ATTEMPTS=1
export AWS_PAGER=""

aws() {
	command aws --endpoint-url "$EP" --cli-read-timeout 300 --cli-connect-timeout 10 "$@"
}

mysql_q() {
	local port="$1" sql="$2"
	MYSQL_PWD="$PASS" mysql --protocol=tcp --get-server-public-key --connect-timeout=5 \
		-h 127.0.0.1 -P "$port" -u "$USER" "$DB" -N -e "$sql"
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

command -v mysql >/dev/null || {
	echo "FAIL: mysql client required" >&2
	exit 1
}

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

wait_mysql() {
	local port="$1"
	for _ in $(seq 1 60); do
		if mysql_q "$port" 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: mysql not ready on 127.0.0.1:${port}" >&2
	return 1
}

start_localstack_persist() {
	echo "start localstack (PERSISTENCE=1)"
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

echo "== create mysql with --port ${HOST_PORT} =="
aws rds create-db-instance \
	--db-instance-identifier "$ID" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--port "$HOST_PORT" >/dev/null

wait_endpoint_port "$ID" "$HOST_PORT" >/dev/null
wait_mysql "$HOST_PORT"
mysql_q "$HOST_PORT" \
	"CREATE TABLE IF NOT EXISTS persist_smoke (id INT PRIMARY KEY, note VARCHAR(64));
	 INSERT INTO persist_smoke (id, note) VALUES (1, 'mysql-keep')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null
NOTE="$(mysql_q "$HOST_PORT" "SELECT note FROM persist_smoke WHERE id = 1")"
[[ "$NOTE" == "mysql-keep" ]] || {
	echo "FAIL: seed row missing (note=${NOTE})" >&2
	exit 1
}

echo "== PERSISTENCE recreate keeps host port + SQL row =="
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
wait_mysql "$HOST_PORT"
NOTE="$(mysql_q "$HOST_PORT" "SELECT note FROM persist_smoke WHERE id = 1")"
[[ "$NOTE" == "mysql-keep" ]] || {
	echo "FAIL: data missing after recreate (note=${NOTE})" >&2
	exit 1
}
echo "OK: PERSISTENCE recreate kept mysql ${ID}@${HOST_PORT} row=mysql-keep"
