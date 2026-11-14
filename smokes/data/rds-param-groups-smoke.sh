#!/usr/bin/env bash
# Apply DB / cluster parameter groups to Docker MySQL/Postgres (#703).
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
MYSQL_PG="sw703-mysql-${TS}"
MYSQL_ID="sw703-mysql-i-${TS}"
CLUSTER_PG="sw703-amysql-pg-${TS}"
CLUSTER="sw703-amysql-${TS}"
READER="${CLUSTER}-r"
PG_PG="sw703-pg-${TS}"
PG_ID="sw703-pg-i-${TS}"
DB="awsbox"
PASS="AwsboxRds1!"
USER="awsbox"
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_MAX_ATTEMPTS=1
export AWS_PAGER=""

aws() {
	command aws --endpoint-url "$EP" --cli-read-timeout 300 --cli-connect-timeout 10 "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$READER" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$MYSQL_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$PG_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-parameter-group --db-parameter-group-name "$MYSQL_PG" >/dev/null 2>&1 || true
	aws rds delete-db-parameter-group --db-parameter-group-name "$PG_PG" >/dev/null 2>&1 || true
	aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v mysql >/dev/null || {
	echo "FAIL: mysql client required" >&2
	exit 1
}
command -v psql >/dev/null || {
	echo "FAIL: psql required" >&2
	exit 1
}

mysql_q() {
	local host="$1" port="$2" user="$3" pass="$4" sql="$5"
	MYSQL_PWD="$pass" mysql --protocol=tcp --get-server-public-key --connect-timeout=5 \
		-h "$host" -P "$port" -u "$user" "$DB" -N -e "$sql"
}

wait_mysql() {
	local host="$1" port="$2" user="$3" pass="$4"
	local i
	for i in $(seq 1 60); do
		if mysql_q "$host" "$port" "$user" "$pass" 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: mysql not ready on ${host}:${port}" >&2
	return 1
}

wait_pg() {
	local host="$1" port="$2"
	local i
	for i in $(seq 1 60); do
		if PGPASSWORD="$PASS" psql -h "$host" -p "$port" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: postgres not ready on ${host}:${port}" >&2
	return 1
}

endpoint_port() {
	local id="$1"
	local host="" port=""
	local _
	for _ in $(seq 1 45); do
		host="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
		port="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
		if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]] \
			&& [[ -n "$port" && "$port" != "None" ]]; then
			echo "127.0.0.1 $port"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: no endpoint for $id" >&2
	return 1
}

echo "mysql parameter group ${MYSQL_PG}"
aws rds create-db-parameter-group \
	--db-parameter-group-name "$MYSQL_PG" \
	--db-parameter-group-family mysql8.0 \
	--description "sw703 mysql" >/dev/null
aws rds modify-db-parameter-group \
	--db-parameter-group-name "$MYSQL_PG" \
	--parameters \
	"ParameterName=sql_mode,ParameterValue=,ApplyMethod=immediate" \
	"ParameterName=max_connections,ParameterValue=50,ApplyMethod=immediate" >/dev/null

aws rds create-db-instance \
	--db-instance-identifier "$MYSQL_ID" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--db-parameter-group-name "$MYSQL_PG" >/dev/null

read -r M_HOST M_PORT < <(endpoint_port "$MYSQL_ID")
wait_mysql "$M_HOST" "$M_PORT" "$USER" "$PASS"
ROW="$(mysql_q "$M_HOST" "$M_PORT" "$USER" "$PASS" 'SELECT @@sql_mode, @@max_connections')"
echo "mysql globals: $ROW"
echo "$ROW" | awk -F'\t' '$2==50 {exit 0} {exit 1}' || {
	echo "FAIL: expected max_connections=50 got: $ROW" >&2
	exit 1
}
# empty sql_mode → first field empty (leading tab) or just the number on some clients
SQL_MODE="$(mysql_q "$M_HOST" "$M_PORT" "$USER" "$PASS" 'SELECT @@sql_mode')"
[[ -z "$SQL_MODE" ]] || {
	echo "FAIL: expected empty sql_mode got: '${SQL_MODE}'" >&2
	exit 1
}
echo "OK: mysql instance params sql_mode='' max_connections=50"

aws rds modify-db-parameter-group \
	--db-parameter-group-name "$MYSQL_PG" \
	--parameters \
	"ParameterName=max_connections,ParameterValue=75,ApplyMethod=immediate" >/dev/null
aws rds reboot-db-instance --db-instance-identifier "$MYSQL_ID" >/dev/null
wait_mysql "$M_HOST" "$M_PORT" "$USER" "$PASS"
MC="$(mysql_q "$M_HOST" "$M_PORT" "$USER" "$PASS" 'SELECT @@max_connections')"
[[ "$MC" == "75" ]] || {
	echo "FAIL: after modify+reboot expected max_connections=75 got: ${MC}" >&2
	exit 1
}
echo "OK: mysql modify + reboot → max_connections=75"

echo "aurora-mysql cluster parameter group ${CLUSTER_PG}"
aws rds create-db-cluster-parameter-group \
	--db-cluster-parameter-group-name "$CLUSTER_PG" \
	--db-parameter-group-family aurora-mysql8.0 \
	--description "sw703 aurora mysql" >/dev/null
aws rds modify-db-cluster-parameter-group \
	--db-cluster-parameter-group-name "$CLUSTER_PG" \
	--parameters \
	"ParameterName=sql_mode,ParameterValue=,ApplyMethod=immediate" \
	"ParameterName=max_connections,ParameterValue=50,ApplyMethod=immediate" >/dev/null

aws rds create-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--database-name "$DB" \
	--db-cluster-parameter-group-name "$CLUSTER_PG" >/dev/null

W_HOST=""
W_PORT=""
for _ in $(seq 1 45); do
	W_HOST="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].Endpoint' --output text)"
	W_PORT="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].Port' --output text)"
	if [[ "$W_HOST" == "localhost" || "$W_HOST" == "127.0.0.1" ]] \
		&& [[ -n "$W_PORT" && "$W_PORT" != "None" ]]; then
		W_HOST=127.0.0.1
		break
	fi
	sleep 2
done
[[ -n "$W_PORT" && "$W_PORT" != "None" ]] || {
	echo "FAIL: aurora writer endpoint" >&2
	exit 1
}
wait_mysql "$W_HOST" "$W_PORT" "$USER" "$PASS"

aws rds create-db-instance \
	--db-instance-identifier "$READER" \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--db-instance-class db.t3.micro >/dev/null
read -r R_HOST R_PORT < <(endpoint_port "$READER")
wait_mysql "$R_HOST" "$R_PORT" "$USER" "$PASS"

for role in writer reader; do
	if [[ "$role" == "writer" ]]; then
		h="$W_HOST"
		p="$W_PORT"
	else
		h="$R_HOST"
		p="$R_PORT"
	fi
	SM="$(mysql_q "$h" "$p" "$USER" "$PASS" 'SELECT @@sql_mode')"
	MC="$(mysql_q "$h" "$p" "$USER" "$PASS" 'SELECT @@max_connections')"
	[[ -z "$SM" ]] || {
		echo "FAIL: aurora ${role} sql_mode='${SM}'" >&2
		exit 1
	}
	[[ "$MC" == "50" ]] || {
		echo "FAIL: aurora ${role} max_connections=${MC}" >&2
		exit 1
	}
	echo "OK: aurora-mysql ${role} params sql_mode='' max_connections=50"
done

echo "postgres parameter group ${PG_PG}"
aws rds create-db-parameter-group \
	--db-parameter-group-name "$PG_PG" \
	--db-parameter-group-family postgres16 \
	--description "sw703 postgres" >/dev/null
aws rds modify-db-parameter-group \
	--db-parameter-group-name "$PG_PG" \
	--parameters \
	"ParameterName=work_mem,ParameterValue=4096,ApplyMethod=immediate" >/dev/null

aws rds create-db-instance \
	--db-instance-identifier "$PG_ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--db-parameter-group-name "$PG_PG" >/dev/null

read -r P_HOST P_PORT < <(endpoint_port "$PG_ID")
wait_pg "$P_HOST" "$P_PORT"
WM="$(PGPASSWORD="$PASS" psql -h "$P_HOST" -p "$P_PORT" -U "$USER" -d "$DB" -Atc 'SHOW work_mem')"
# 4096 (kB) or 4MB depending on server formatting
echo "postgres work_mem=${WM}"
echo "$WM" | grep -qiE '^(4096|4MB|4 MB)$' || {
	echo "FAIL: expected work_mem 4096/4MB got: ${WM}" >&2
	exit 1
}
echo "OK: postgres work_mem=${WM}"

aws rds modify-db-parameter-group \
	--db-parameter-group-name "$PG_PG" \
	--parameters \
	"ParameterName=work_mem,ParameterValue=8192,ApplyMethod=immediate" >/dev/null
aws rds reboot-db-instance --db-instance-identifier "$PG_ID" >/dev/null
wait_pg "$P_HOST" "$P_PORT"
WM2="$(PGPASSWORD="$PASS" psql -h "$P_HOST" -p "$P_PORT" -U "$USER" -d "$DB" -Atc 'SHOW work_mem')"
echo "$WM2" | grep -qiE '^(8192|8MB|8 MB)$' || {
	echo "FAIL: after modify+reboot expected work_mem 8192/8MB got: ${WM2}" >&2
	exit 1
}
echo "OK: postgres modify + reboot → work_mem=${WM2}"

echo "OK: rds param groups smoke"
