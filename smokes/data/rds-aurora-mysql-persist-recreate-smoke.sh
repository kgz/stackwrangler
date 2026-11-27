#!/usr/bin/env bash
# #743: Aurora MySQL writer + reader SQL + cluster endpoints survive hard
# PERSISTENCE=1 LocalEmu recreate (docker-rm sidecars; volumes + meta kept) —
# same bar as MySQL #743 / Postgres #705.
#
# Requires an already-up stackwrangler compose project for this worktree.
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
CLUSTER="awsbox-amysql-persist-${TS}"
READER="${CLUSTER}-r"
USER="awsbox"
PASS="AwsboxRds1!"
DB="awsbox"
WRITER_PORT=$((17000 + (TS % 1000)))
READER_PORT=$((WRITER_PORT + 1))
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"
OVERRIDE="${TMPDIR:-/tmp}/awsbox-amysql-persist-override-${TS}.yml"
STATE_VOL="awsl-amysql-persist-${TS}"
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
	"${BASE_COMPOSE[@]}" up -d --force-recreate -V --no-deps localstack >/dev/null 2>&1 || true
	wait_localemu >/dev/null 2>&1 || true
	docker volume rm "$STATE_VOL" >/dev/null 2>&1 || true
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$READER" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 || true
	docker rm -f "localemu-rds-${READER}" "localemu-rds-${CLUSTER}" >/dev/null 2>&1 || true
	restore_default_localstack
}
trap cleanup EXIT

command -v mysql >/dev/null || {
	echo "FAIL: mysql client required" >&2
	exit 1
}

# stop_grace_period must cover ON_SHUTDOWN dill save (compose default ~10s is too short).
cat >"$OVERRIDE" <<YAML
services:
  localstack:
    stop_grace_period: 90s
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${STATE_VOL}:/var/lib/localemu
volumes:
  ${STATE_VOL}:
    name: ${STATE_VOL}
YAML

wait_cluster_port() {
	local cid="$1" want="$2"
	local host="" port=""
	for _ in $(seq 1 120); do
		host="$(aws rds describe-db-clusters --db-cluster-identifier "$cid" \
			--query 'DBClusters[0].Endpoint' --output text 2>/dev/null || true)"
		port="$(aws rds describe-db-clusters --db-cluster-identifier "$cid" \
			--query 'DBClusters[0].Port' --output text 2>/dev/null || true)"
		if [[ "$port" == "$want" ]] && [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
			echo "${host} ${port}"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: cluster Endpoint/Port host=${host:-none} port=${port:-none} want ${want}" >&2
	return 1
}

wait_instance_port() {
	local id="$1" want="$2"
	local host="" port=""
	for _ in $(seq 1 120); do
		host="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
		port="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
		if [[ "$port" == "$want" ]] && [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
			echo "${host} ${port}"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: instance ${id} Endpoint host=${host:-none} port=${port:-none} want ${want}" >&2
	return 1
}

wait_mysql() {
	local port="$1"
	for _ in $(seq 1 90); do
		if mysql_q "$port" 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: mysql not ready on 127.0.0.1:${port}" >&2
	return 1
}

wait_reader_row() {
	local port="$1" want="$2"
	local note=""
	for _ in $(seq 1 60); do
		note="$(mysql_q "$port" "SELECT note FROM persist_smoke WHERE id = 1" 2>/dev/null || true)"
		if [[ "$note" == "$want" ]]; then
			echo "$note"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: reader row missing (got '${note}')" >&2
	return 1
}

wait_container() {
	local name="$1"
	for _ in $(seq 1 120); do
		if docker inspect "$name" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: container ${name} not restored" >&2
	return 1
}

start_localstack_persist() {
	echo "start localstack (PERSISTENCE=1)"
	"${COMPOSE[@]}" up -d --no-deps localstack >/dev/null
	wait_localemu
	sleep 3
}

recreate_localstack_persist() {
	# Graceful stop first so ON_SHUTDOWN flushes moto state (clusters + instances).
	echo "recreate localstack (PERSISTENCE=1, stop+force)"
	"${COMPOSE[@]}" stop localstack >/dev/null
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

echo "== create aurora-mysql cluster ${CLUSTER} --port ${WRITER_PORT} =="
aws rds create-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--database-name "$DB" \
	--port "$WRITER_PORT" >/dev/null

wait_cluster_port "$CLUSTER" "$WRITER_PORT" >/dev/null
wait_mysql "$WRITER_PORT"

echo "== create reader ${READER} --port ${READER_PORT} =="
aws rds create-db-instance \
	--db-instance-identifier "$READER" \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--db-instance-class db.t3.micro \
	--port "$READER_PORT" >/dev/null

wait_instance_port "$READER" "$READER_PORT" >/dev/null
wait_mysql "$READER_PORT"

mysql_q "$WRITER_PORT" \
	"CREATE TABLE IF NOT EXISTS persist_smoke (id INT PRIMARY KEY, note VARCHAR(64));
	 INSERT INTO persist_smoke (id, note) VALUES (1, 'aurora-keep')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null
wait_reader_row "$READER_PORT" "aurora-keep" >/dev/null

# Snapshot cluster endpoints before recreate for equality checks.
W_HOST_BEFORE="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
	--query 'DBClusters[0].Endpoint' --output text)"
W_PORT_BEFORE="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
	--query 'DBClusters[0].Port' --output text)"
R_EP_BEFORE="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
	--query 'DBClusters[0].ReaderEndpoint' --output text)"
R_HOST_BEFORE="$(aws rds describe-db-instances --db-instance-identifier "$READER" \
	--query 'DBInstances[0].Endpoint.Address' --output text)"
R_PORT_BEFORE="$(aws rds describe-db-instances --db-instance-identifier "$READER" \
	--query 'DBInstances[0].Endpoint.Port' --output text)"

echo "== PERSISTENCE hard recreate (docker-rm sidecars; volumes kept) =="
docker volume inspect "localemu-rds-${CLUSTER}-data" >/dev/null
docker volume inspect "localemu-rds-${READER}-data" >/dev/null
docker rm -f "localemu-rds-${READER}" "localemu-rds-${CLUSTER}" >/dev/null
recreate_localstack_persist
wait_container "localemu-rds-${CLUSTER}"
wait_container "localemu-rds-${READER}"

W_AFTER="$(wait_cluster_port "$CLUSTER" "$WRITER_PORT")"
W_HOST_AFTER="$(echo "$W_AFTER" | awk '{print $1}')"
W_PORT_AFTER="$(echo "$W_AFTER" | awk '{print $2}')"
[[ "$W_HOST_AFTER" == "$W_HOST_BEFORE" && "$W_PORT_AFTER" == "$W_PORT_BEFORE" ]] || {
	echo "FAIL: cluster Endpoint changed ${W_HOST_BEFORE}:${W_PORT_BEFORE} → ${W_HOST_AFTER}:${W_PORT_AFTER}" >&2
	exit 1
}
R_EP_AFTER="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
	--query 'DBClusters[0].ReaderEndpoint' --output text)"
[[ "$R_EP_AFTER" == "$R_EP_BEFORE" ]] || {
	echo "FAIL: ReaderEndpoint changed ${R_EP_BEFORE} → ${R_EP_AFTER}" >&2
	exit 1
}
R_AFTER="$(wait_instance_port "$READER" "$READER_PORT")"
R_HOST_AFTER="$(echo "$R_AFTER" | awk '{print $1}')"
R_PORT_AFTER="$(echo "$R_AFTER" | awk '{print $2}')"
[[ "$R_HOST_AFTER" == "$R_HOST_BEFORE" && "$R_PORT_AFTER" == "$R_PORT_BEFORE" ]] || {
	echo "FAIL: reader Endpoint changed ${R_HOST_BEFORE}:${R_PORT_BEFORE} → ${R_HOST_AFTER}:${R_PORT_AFTER}" >&2
	exit 1
}

wait_mysql "$WRITER_PORT"
NOTE_W="$(mysql_q "$WRITER_PORT" "SELECT note FROM persist_smoke WHERE id = 1")"
[[ "$NOTE_W" == "aurora-keep" ]] || {
	echo "FAIL: writer data missing after recreate (note=${NOTE_W})" >&2
	exit 1
}
wait_mysql "$READER_PORT"
NOTE_R="$(wait_reader_row "$READER_PORT" "aurora-keep")"
[[ "$NOTE_R" == "aurora-keep" ]] || {
	echo "FAIL: reader data missing after recreate (note=${NOTE_R})" >&2
	exit 1
}

echo "OK: PERSISTENCE hard recreate kept aurora-mysql ${CLUSTER} writer ${W_HOST_AFTER}:${W_PORT_AFTER} reader ${R_HOST_AFTER}:${R_PORT_AFTER}"
