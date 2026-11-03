#!/usr/bin/env bash
# Sad path: wrong master password → Postgres auth failure (not SQL success).
# Happy: ./bin/rds-smoke.sh
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
ID="awsbox-rds-authz-${TS}"
USER="awsbox"
PASS="AwsboxRds1!"
WRONG="DefinitelyWrongPass1!"
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
	echo "FAIL: psql required" >&2
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
	if [[ -n "$PORT" && "$PORT" != "None" ]]; then
		if [[ "$HOST" == "localhost" || "$HOST" == "127.0.0.1" ]] \
			|| docker ps --format '{{.Names}}' | grep -q "localemu-rds-${ID}"; then
			HOST=127.0.0.1
			break
		fi
	fi
	sleep 2
done
[[ -n "$PORT" && "$PORT" != "None" ]] || {
	echo "FAIL: no RDS endpoint (RDS_DOCKER_BACKEND=1?)" >&2
	exit 1
}
HOST=127.0.0.1

echo "waiting for postgres on ${HOST}:${PORT}…"
for _ in $(seq 1 60); do
	if PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

# Good password must still work (instance is up).
PGPASSWORD="$PASS" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1' >/dev/null

set +e
OUT="$(
	PGPASSWORD="$WRONG" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c 'SELECT 1' 2>&1
)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
	echo "FAIL: wrong password connected; expected auth failure" >&2
	echo "$OUT" >&2
	exit 1
fi
if ! echo "$OUT" | grep -qiE 'password authentication failed|fe_sendauth|authentication failed|FATAL'; then
	echo "FAIL: expected auth failure in output:" >&2
	echo "$OUT" >&2
	exit 1
fi

echo "OK: RDS wrong password → auth denied (${ID} @ ${HOST}:${PORT})"
echo "$OUT" | head -2
