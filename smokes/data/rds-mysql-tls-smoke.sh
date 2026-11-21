#!/usr/bin/env bash
# RDS MySQL presents a SAN'd server cert chained to .awsbox/tls/rds-ca.pem (#765).
# Clients that VERIFY_IDENTITY against 127.0.0.1 / localhost must succeed.
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
DB_ID="awsbox-mysql-tls-${TS}"
DB="awsbox"
PASS="TlsSmokePass1a"
KEEP="${STACKWRANGLER_RDS_KEEP:-${AWSBOX_RDS_KEEP:-0}}"
CA_PATH="${ROOT}/.awsbox/tls/rds-ca.pem"

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
	aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v mysql >/dev/null || {
	echo "FAIL: mysql client required" >&2
	exit 1
}
command -v openssl >/dev/null || {
	echo "FAIL: openssl required" >&2
	exit 1
}

echo "create mysql ${DB_ID}"
aws rds create-db-instance \
	--db-instance-identifier "$DB_ID" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0 \
	--master-username awsbox \
	--master-user-password "$PASS" \
	--allocated-storage 20 \
	--db-name "$DB" >/dev/null

host=""
port=""
for _ in $(seq 1 90); do
	desc="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" 2>/dev/null || true)"
	status="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["DBInstances"][0].get("DBInstanceStatus",""))' "$desc" 2>/dev/null || true)"
	if [[ "$status" == "available" ]]; then
		host="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["DBInstances"][0]["Endpoint"]["Address"])' "$desc")"
		port="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["DBInstances"][0]["Endpoint"]["Port"])' "$desc")"
		break
	fi
	if [[ "$status" == "create-failed" ]]; then
		echo "FAIL: create-failed" >&2
		exit 1
	fi
	sleep 2
done
[[ -n "$host" && -n "$port" ]] || {
	echo "FAIL: instance never available" >&2
	exit 1
}

echo "endpoint ${host}:${port}"
[[ -f "$CA_PATH" ]] || {
	echo "FAIL: missing published RDS CA at ${CA_PATH}" >&2
	exit 1
}

# Wait until mysqld accepts TCP (TLS handshake may still be warming).
for _ in $(seq 1 60); do
	if MYSQL_PWD="$PASS" mysql --protocol=tcp --connect-timeout=3 \
		-h 127.0.0.1 -P "$port" -u awsbox "$DB" -N -e 'SELECT 1' >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

echo "openssl: check SAN on presented cert"
text="$(
	openssl s_client -starttls mysql -connect "127.0.0.1:${port}" </dev/null 2>/dev/null \
		| openssl x509 -noout -text 2>/dev/null || true
)"
echo "$text" | grep -q 'DNS:localhost' || {
	echo "FAIL: presented cert missing DNS:localhost SAN" >&2
	echo "$text" | grep -A3 'Subject Alternative Name' >&2 || echo "$text" | head -40 >&2
	exit 1
}
echo "$text" | grep -q 'IP Address:127.0.0.1' || {
	echo "FAIL: presented cert missing IP:127.0.0.1 SAN" >&2
	exit 1
}
echo "$text" | grep -qi 'Auto_Generated_Server_Certificate' && {
	echo "FAIL: still serving MySQL auto-generated server cert" >&2
	exit 1
}

echo "mysql VERIFY_IDENTITY via 127.0.0.1 + rds-ca.pem"
MYSQL_PWD="$PASS" mysql --protocol=tcp --connect-timeout=5 \
	--ssl-mode=VERIFY_IDENTITY --ssl-ca="$CA_PATH" \
	-h 127.0.0.1 -P "$port" -u awsbox "$DB" -N -e 'SELECT 1' | grep -qx 1

echo "mysql VERIFY_IDENTITY via localhost + rds-ca.pem"
MYSQL_PWD="$PASS" mysql --protocol=tcp --connect-timeout=5 \
	--ssl-mode=VERIFY_IDENTITY --ssl-ca="$CA_PATH" \
	-h localhost -P "$port" -u awsbox "$DB" -N -e 'SELECT 1' | grep -qx 1

echo "OK rds-mysql-tls-smoke (${host}:${port})"
