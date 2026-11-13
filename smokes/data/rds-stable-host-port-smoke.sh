#!/usr/bin/env bash
# Stable selectable RDS host ports (#705): --port / tag, reboot, conflict.
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
ID="awsbox-rds-port-${TS}"
ID2="awsbox-rds-port2-${TS}"
IDT="awsbox-rds-portt-${TS}"
USER="awsbox"
PASS="AwsboxRds1!"
DB="awsbox"
# High ports avoid colliding with host postgres/mysql.
HOST_PORT=$((13000 + (TS % 2000)))
TAG_PORT=$((HOST_PORT + 1))
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$ID2" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$IDT" --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v psql >/dev/null || {
	echo "FAIL: psql required for RDS host-port smoke" >&2
	exit 1
}

wait_endpoint() {
	local id="$1" want="${2:-}"
	local host="" port=""
	for _ in $(seq 1 90); do
		host="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
		port="$(aws rds describe-db-instances --db-instance-identifier "$id" \
			--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
		if [[ -n "$port" && "$port" != "None" ]]; then
			if [[ -z "$want" || "$port" == "$want" ]]; then
				echo "${host:-127.0.0.1} ${port}"
				return 0
			fi
		fi
		sleep 2
	done
	echo "FAIL: no endpoint port for ${id} (want=${want:-any})" >&2
	return 1
}

wait_psql() {
	local host="$1" port="$2"
	for _ in $(seq 1 60); do
		if PGPASSWORD="$PASS" psql -h "$host" -p "$port" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "FAIL: psql not ready on ${host}:${port}" >&2
	return 1
}

echo "create with --port ${HOST_PORT}"
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

read -r HOST PORT < <(wait_endpoint "$ID" "$HOST_PORT")
[[ "$HOST" == *rds.amazonaws.com ]] && HOST=127.0.0.1
HOST="${HOST:-127.0.0.1}"
[[ "$PORT" == "$HOST_PORT" ]] || {
	echo "FAIL: describe Port=${PORT} want ${HOST_PORT}" >&2
	exit 1
}
wait_psql "$HOST" "$PORT"
PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 \
	-c "CREATE TABLE IF NOT EXISTS port_smoke (id int PRIMARY KEY); INSERT INTO port_smoke VALUES (1) ON CONFLICT DO NOTHING;"

echo "reboot keeps host port"
aws rds reboot-db-instance --db-instance-identifier "$ID" >/dev/null
read -r HOST2 PORT2 < <(wait_endpoint "$ID" "$HOST_PORT")
[[ "$HOST2" == *rds.amazonaws.com ]] && HOST2=127.0.0.1
HOST2="${HOST2:-127.0.0.1}"
[[ "$PORT2" == "$HOST_PORT" ]] || {
	echo "FAIL: after reboot Port=${PORT2} want ${HOST_PORT}" >&2
	exit 1
}
wait_psql "$HOST2" "$PORT2"

echo "conflict on same --port returns clear error"
set +e
ERR="$(aws rds create-db-instance \
	--db-instance-identifier "$ID2" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--port "$HOST_PORT" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || {
	echo "FAIL: expected port conflict to fail" >&2
	exit 1
}
echo "$ERR" | grep -qiE 'Host port|already in use|InvalidParameterValue' || {
	echo "FAIL: conflict error unclear: ${ERR}" >&2
	exit 1
}

echo "create via stackwrangler:host-port tag → ${TAG_PORT}"
aws rds create-db-instance \
	--db-instance-identifier "$IDT" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" \
	--tags "Key=stackwrangler:host-port,Value=${TAG_PORT}" >/dev/null

read -r HOSTT PORTT < <(wait_endpoint "$IDT" "$TAG_PORT")
[[ "$HOSTT" == *rds.amazonaws.com ]] && HOSTT=127.0.0.1
HOSTT="${HOSTT:-127.0.0.1}"
[[ "$PORTT" == "$TAG_PORT" ]] || {
	echo "FAIL: tag Port=${PORTT} want ${TAG_PORT}" >&2
	exit 1
}
wait_psql "$HOSTT" "$PORTT"

echo "OK: rds stable host-port ${ID}@${HOST_PORT} tag=${TAG_PORT} reboot+conflict"
