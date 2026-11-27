#!/usr/bin/env bash
# Aurora MySQL FailoverDBCluster: former reader becomes writable and
# IsClusterWriter follows it (#225). The cluster endpoint host:port from
# before the failover keeps answering and reaches the new writer (#827).
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
CLUSTER="awsbox-amysql-fo-${TS}"
READER="${CLUSTER}-r"
DB="awsbox"
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_MAX_ATTEMPTS=1
export AWS_PAGER=""

aws() {
	command aws --endpoint-url "$EP" --cli-read-timeout 300 --cli-connect-timeout 10 "$@"
}

mysql_q() {
	local host="$1" port="$2" user="$3" pass="$4" sql="$5"
	MYSQL_PWD="$pass" mysql --protocol=tcp --get-server-public-key --connect-timeout=5 \
		-h "$host" -P "$port" -u "$user" "$DB" -N -e "$sql"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$READER" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v mysql >/dev/null || {
	echo "FAIL: mysql client required" >&2
	exit 1
}

secret_field() {
	python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

wait_sql() {
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

echo "aurora-mysql cluster ${CLUSTER}"
aws rds create-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--master-username awsbox \
	--manage-master-user-password \
	--database-name "$DB" >/dev/null

W_HOST=""
W_PORT=""
W_ARN=""
for _ in $(seq 1 30); do
	W_HOST="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].Endpoint' --output text)"
	W_PORT="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].Port' --output text)"
	W_ARN="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)"
	if [[ "$W_HOST" == "localhost" || "$W_HOST" == "127.0.0.1" ]] \
		&& [[ "$W_PORT" != "None" && -n "$W_PORT" ]] \
		&& [[ "$W_ARN" == arn:aws:secretsmanager:* ]]; then
		break
	fi
	sleep 2
done
[[ "$W_HOST" == "localhost" || "$W_HOST" == "127.0.0.1" ]] || {
	echo "FAIL: writer endpoint ${W_HOST}:${W_PORT} arn=${W_ARN}" >&2
	exit 1
}
RO_HOST="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
	--query 'DBClusters[0].ReaderEndpoint' --output text)"
W_JSON="$(aws secretsmanager get-secret-value --secret-id "$W_ARN" --query SecretString --output text)"
W_USER="$(secret_field "$W_JSON" username)"
W_PASS="$(secret_field "$W_JSON" password)"
wait_sql 127.0.0.1 "$W_PORT" "$W_USER" "$W_PASS"

echo "reader instance ${READER}"
aws rds create-db-instance \
	--db-instance-identifier "$READER" \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--db-instance-class db.t3.micro >/dev/null

R_HOST=""
R_PORT=""
for _ in $(seq 1 30); do
	R_HOST="$(aws rds describe-db-instances --db-instance-identifier "$READER" \
		--query 'DBInstances[0].Endpoint.Address' --output text)"
	R_PORT="$(aws rds describe-db-instances --db-instance-identifier "$READER" \
		--query 'DBInstances[0].Endpoint.Port' --output text)"
	if [[ "$R_HOST" == "localhost" || "$R_HOST" == "127.0.0.1" ]] \
		&& [[ "$R_PORT" != "None" && -n "$R_PORT" && "$R_PORT" != "$W_PORT" ]]; then
		break
	fi
	sleep 2
done
[[ "$R_PORT" != "$W_PORT" ]] || {
	echo "FAIL: reader port ${R_PORT} matches writer" >&2
	exit 1
}

mysql_q 127.0.0.1 "$W_PORT" "$W_USER" "$W_PASS" \
	"CREATE TABLE IF NOT EXISTS awsbox_fo (id INT PRIMARY KEY, note VARCHAR(64));
	 INSERT INTO awsbox_fo (id, note) VALUES (1, 'pre-failover')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null

NOTE=""
for _ in $(seq 1 30); do
	NOTE="$(mysql_q 127.0.0.1 "$R_PORT" "$W_USER" "$W_PASS" \
		"SELECT note FROM awsbox_fo WHERE id = 1" 2>/dev/null || true)"
	[[ "$NOTE" == "pre-failover" ]] && break
	sleep 2
done
[[ "$NOTE" == "pre-failover" ]] || {
	echo "FAIL: reader did not replicate (got '${NOTE}')" >&2
	docker logs "localemu-rds-${READER}" 2>&1 | tail -40 >&2 || true
	exit 1
}

set +e
RO="$(mysql_q 127.0.0.1 "$R_PORT" "$W_USER" "$W_PASS" \
	"INSERT INTO awsbox_fo (id, note) VALUES (2, 'nope')" 2>&1)"
RO_RC=$?
set -e
[[ "$RO_RC" -ne 0 ]]
echo "$RO" | grep -qiE 'read-only|read only|ERROR 1290' || {
	echo "FAIL: reader accepted a write before failover: $RO" >&2
	exit 1
}

echo "failover-db-cluster → ${READER}"
aws rds failover-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--target-db-instance-identifier "$READER" >/dev/null

NEW_PORT=""
WRITER_ID=""
for _ in $(seq 1 30); do
	NEW_PORT="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query 'DBClusters[0].Port' --output text)"
	WRITER_ID="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" \
		--query "DBClusters[0].DBClusterMembers[?IsClusterWriter==\`true\`].DBInstanceIdentifier | [0]" \
		--output text)"
	if [[ "$WRITER_ID" == "$READER" ]]; then
		break
	fi
	sleep 2
done

[[ "$WRITER_ID" == "$READER" ]] || {
	echo "FAIL: IsClusterWriter=${WRITER_ID} expected ${READER}" >&2
	aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" >&2 || true
	exit 1
}
# Real AWS keeps the cluster endpoint name and port across a failover.
[[ "$NEW_PORT" == "$W_PORT" ]] || {
	echo "FAIL: cluster Port moved ${W_PORT} -> ${NEW_PORT} on failover" >&2
	exit 1
}

# A client holding the pre-failover endpoint reconnects and writes.
wait_sql 127.0.0.1 "$W_PORT" "$W_USER" "$W_PASS"
mysql_q 127.0.0.1 "$W_PORT" "$W_USER" "$W_PASS" \
	"INSERT INTO awsbox_fo (id, note) VALUES (3, 'post-failover')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null
EP_HOST="$(mysql_q 127.0.0.1 "$W_PORT" "$W_USER" "$W_PASS" 'SELECT @@hostname')"
NEW_HOST="$(docker inspect -f '{{.Config.Hostname}}' "localemu-rds-${READER}")"
[[ "$EP_HOST" == "$NEW_HOST" ]] || {
	echo "FAIL: cluster endpoint reached ${EP_HOST}, new writer is ${NEW_HOST}" >&2
	exit 1
}
POST="$(mysql_q 127.0.0.1 "$R_PORT" "$W_USER" "$W_PASS" \
	"SELECT note FROM awsbox_fo WHERE id = 3")"
[[ "$POST" == "post-failover" ]] || {
	echo "FAIL: write via cluster endpoint not on new writer (got '${POST}')" >&2
	exit 1
}

# Reader endpoint (same port; no readers left, so it reaches the writer like AWS).
[[ "$RO_HOST" == "localhost" ]] && RO_HOST=127.0.0.1
RO_NOTE="$(mysql_q "$RO_HOST" "$W_PORT" "$W_USER" "$W_PASS" \
	"SELECT note FROM awsbox_fo WHERE id = 1")"
[[ "$RO_NOTE" == "pre-failover" ]] || {
	echo "FAIL: reader endpoint ${RO_HOST}:${W_PORT} after failover (got '${RO_NOTE}')" >&2
	exit 1
}

echo "OK: aurora-mysql failover ${CLUSTER} writer now ${READER}; cluster endpoint 127.0.0.1:${W_PORT} unchanged"
