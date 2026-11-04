#!/usr/bin/env bash
# Aurora MySQL cluster: writer via managed secret, reader is read-only.
# Also a standalone mysql instance with ManageMasterUserPassword.
# Happy: ./bin/rds-smoke.sh (Postgres)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
STANDALONE="awsbox-mysql-${TS}"
CLUSTER="awsbox-amysql-${TS}"
READER="${CLUSTER}-r"
DB="awsbox"
WRONG="DefinitelyWrongPass1"
KEEP="${AWSBOX_RDS_KEEP:-0}"

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
	aws rds delete-db-instance --db-instance-identifier "$STANDALONE" --skip-final-snapshot >/dev/null 2>&1 || true
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

echo "standalone mysql ${STANDALONE}"
aws rds create-db-instance \
	--db-instance-identifier "$STANDALONE" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0 \
	--master-username awsbox \
	--manage-master-user-password \
	--allocated-storage 20 \
	--db-name "$DB" >/dev/null

S_HOST=""
S_PORT=""
S_ARN=""
for _ in $(seq 1 30); do
	S_HOST="$(aws rds describe-db-instances --db-instance-identifier "$STANDALONE" \
		--query 'DBInstances[0].Endpoint.Address' --output text)"
	S_PORT="$(aws rds describe-db-instances --db-instance-identifier "$STANDALONE" \
		--query 'DBInstances[0].Endpoint.Port' --output text)"
	S_ARN="$(aws rds describe-db-instances --db-instance-identifier "$STANDALONE" \
		--query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
	if [[ "$S_HOST" == "localhost" || "$S_HOST" == "127.0.0.1" ]] \
		&& [[ "$S_PORT" != "None" && -n "$S_PORT" ]] \
		&& [[ "$S_ARN" == arn:aws:secretsmanager:* ]]; then
		break
	fi
	sleep 2
done
[[ "$S_HOST" == "localhost" || "$S_HOST" == "127.0.0.1" ]] || {
	echo "FAIL: standalone endpoint ${S_HOST}:${S_PORT}" >&2
	exit 1
}
S_JSON="$(aws secretsmanager get-secret-value --secret-id "$S_ARN" --query SecretString --output text)"
S_USER="$(secret_field "$S_JSON" username)"
S_PASS="$(secret_field "$S_JSON" password)"
[[ "$S_USER" == "awsbox" ]]
[[ "$S_PASS" != "P@55w0rd!" && ${#S_PASS} -ge 8 ]]
wait_sql 127.0.0.1 "$S_PORT" "$S_USER" "$S_PASS"
mysql_q 127.0.0.1 "$S_PORT" "$S_USER" "$S_PASS" \
	"CREATE TABLE IF NOT EXISTS awsbox_smoke (id INT PRIMARY KEY, note VARCHAR(64));
	 INSERT INTO awsbox_smoke (id, note) VALUES (1, 'mysql-standalone')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null
NOTE="$(mysql_q 127.0.0.1 "$S_PORT" "$S_USER" "$S_PASS" "SELECT note FROM awsbox_smoke WHERE id = 1")"
[[ "$NOTE" == "mysql-standalone" ]]
set +e
BAD="$(mysql_q 127.0.0.1 "$S_PORT" "$S_USER" "$WRONG" 'SELECT 1' 2>&1)"
BAD_RC=$?
set -e
[[ "$BAD_RC" -ne 0 ]]
echo "$BAD" | grep -qiE 'Access denied|ERROR 1045' || {
	echo "FAIL: standalone wrong password did not deny: $BAD" >&2
	exit 1
}
echo "OK: mysql instance ${STANDALONE} @ 127.0.0.1:${S_PORT} (managed secret)"
aws rds delete-db-instance --db-instance-identifier "$STANDALONE" --skip-final-snapshot >/dev/null

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
W_JSON="$(aws secretsmanager get-secret-value --secret-id "$W_ARN" --query SecretString --output text)"
W_USER="$(secret_field "$W_JSON" username)"
W_PASS="$(secret_field "$W_JSON" password)"
[[ "$W_USER" == "awsbox" ]]
[[ "$W_PASS" != "P@55w0rd!" && ${#W_PASS} -ge 8 ]]
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
	"CREATE TABLE IF NOT EXISTS awsbox_smoke (id INT PRIMARY KEY, note VARCHAR(64));
	 INSERT INTO awsbox_smoke (id, note) VALUES (1, 'aurora-mysql')
	 ON DUPLICATE KEY UPDATE note = VALUES(note);" >/dev/null

NOTE=""
for _ in $(seq 1 30); do
	NOTE="$(mysql_q 127.0.0.1 "$R_PORT" "$W_USER" "$W_PASS" \
		"SELECT note FROM awsbox_smoke WHERE id = 1" 2>/dev/null || true)"
	[[ "$NOTE" == "aurora-mysql" ]] && break
	sleep 2
done
[[ "$NOTE" == "aurora-mysql" ]] || {
	echo "FAIL: reader did not replicate writer row (got '${NOTE}')" >&2
	docker logs "localemu-rds-${READER}" 2>&1 | tail -40 >&2 || true
	exit 1
}

set +e
RO="$(mysql_q 127.0.0.1 "$R_PORT" "$W_USER" "$W_PASS" \
	"INSERT INTO awsbox_smoke (id, note) VALUES (2, 'nope')" 2>&1)"
RO_RC=$?
set -e
[[ "$RO_RC" -ne 0 ]]
echo "$RO" | grep -qiE 'read-only|read only|ERROR 1290' || {
	echo "FAIL: reader accepted a write: $RO" >&2
	exit 1
}

echo "OK: aurora-mysql ${CLUSTER} writer 127.0.0.1:${W_PORT} secret ${W_ARN}; reader 127.0.0.1:${R_PORT} read-only"
