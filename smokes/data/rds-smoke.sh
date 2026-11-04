#!/usr/bin/env bash
# Create a Docker-backed Postgres RDS instance and prove SQL works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
ID="awsbox-rds-${TS}"
USER="awsbox"
PASS="AwsboxRds1!"
DB="awsbox"
KEEP="${AWSBOX_RDS_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$ID" --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v psql >/dev/null || {
	echo "FAIL: psql required for RDS data-plane smoke" >&2
	exit 1
}

aws rds create-db-instance \
	--db-instance-identifier "$ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$USER" \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" >/dev/null

HOST=""
PORT=""
for _ in $(seq 1 90); do
	HOST="$(aws rds describe-db-instances --db-instance-identifier "$ID" \
		--query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
	PORT="$(aws rds describe-db-instances --db-instance-identifier "$ID" \
		--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
	if [[ -n "$HOST" && "$HOST" != "None" && -n "$PORT" && "$PORT" != "None" ]]; then
		if [[ "$HOST" == "localhost" || "$HOST" == "127.0.0.1" ]]; then
			break
		fi
		# Docker backend should rewrite to localhost; if still fake ARN host, wait.
		if docker ps --format '{{.Names}}' | grep -q "localemu-rds-${ID}"; then
			HOST=127.0.0.1
			break
		fi
	fi
	sleep 2
done

if [[ -z "$PORT" || "$PORT" == "None" ]]; then
	echo "FAIL: no RDS endpoint port (is RDS_DOCKER_BACKEND=1 set?)" >&2
	exit 1
fi
HOST="${HOST:-127.0.0.1}"
[[ "$HOST" == *rds.amazonaws.com ]] && HOST=127.0.0.1

echo "waiting for postgres on ${HOST}:${PORT}…"
for _ in $(seq 1 60); do
	if PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS awsbox_smoke (id int PRIMARY KEY, note text);
INSERT INTO awsbox_smoke (id, note) VALUES (1, 'rds-smoke')
  ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;
SELECT note FROM awsbox_smoke WHERE id = 1;
SQL

NOTE="$(PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -Atc "SELECT note FROM awsbox_smoke WHERE id = 1")"
[[ "$NOTE" == "rds-smoke" ]]

echo "OK: rds postgres ${ID} @ ${HOST}:${PORT} (SQL round-trip)"
