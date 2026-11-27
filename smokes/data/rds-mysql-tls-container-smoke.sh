#!/usr/bin/env bash
# RDS MySQL / Aurora MySQL server cert covers the names a *container* dials (#835).
# From a client container, mysql --ssl-mode=VERIFY_IDENTITY + rds-ca.pem must pass for:
#   host.docker.internal (published port; awsvpc tasks / Lambda)
#   localemu-rds-<id> and <id> (container name / network alias on a shared network)
#   <cluster>-writer (Aurora writer alias on localemu-aurora-<cluster>)
# Sad: dialling the container IP (not on the cert) must fail verification.
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
DB_ID="awsbox-tlsc-${TS}"
CLUSTER="awsbox-tlsc-c-${TS}"
NET="awsbox-tlsc-net-${TS}"
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

writer_container() {
	docker ps -q --filter "label=localemu.cluster-id=${CLUSTER}" --filter "label=localemu.is-writer=true" | head -1
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	local w
	w="$(writer_container 2>/dev/null || true)"
	w="$([[ -n "$w" ]] && docker inspect -f '{{index .Config.Labels "localemu.db-instance-id"}}' "$w" 2>/dev/null || true)"
	docker network disconnect "$NET" "localemu-rds-${DB_ID}" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 || true
	docker rm -f "localemu-rds-${DB_ID}" >/dev/null 2>&1 || true
	docker volume rm "localemu-rds-${DB_ID}-data" >/dev/null 2>&1 || true
	if [[ -n "$w" ]]; then
		docker rm -f "localemu-rds-${w}" >/dev/null 2>&1 || true
		docker volume rm "localemu-rds-${w}-data" >/dev/null 2>&1 || true
	fi
	docker network rm "localemu-aurora-${CLUSTER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v docker >/dev/null || {
	echo "FAIL: docker required" >&2
	exit 1
}

# Wait for available; print the instance id's endpoint port.
wait_available() {
	local id="$1" desc status
	for _ in $(seq 1 90); do
		desc="$(aws rds describe-db-instances --db-instance-identifier "$id" 2>/dev/null || true)"
		status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["DBInstances"][0].get("DBInstanceStatus",""))' "$desc" 2>/dev/null || true)"
		if [[ "$status" == "available" ]]; then
			python3 -c 'import json,sys; print(json.loads(sys.argv[1])["DBInstances"][0]["Endpoint"]["Port"])' "$desc"
			return 0
		fi
		[[ "$status" == "create-failed" ]] && break
		sleep 2
	done
	echo "FAIL: ${id} never available (${status:-none})" >&2
	return 1
}

# mysql client in a throwaway container: client_q <net-args> -- <host> <port>
client_q() {
	local net=() host port
	while [[ "$1" != "--" ]]; do
		net+=("$1")
		shift
	done
	shift
	host="$1" port="$2"
	docker run --rm "${net[@]}" -v "${CA_PATH}:/rds-ca.pem:ro" -e MYSQL_PWD="$PASS" \
		--entrypoint mysql "$IMAGE" --protocol=tcp --connect-timeout=5 \
		--ssl-mode=VERIFY_IDENTITY --ssl-ca=/rds-ca.pem \
		-h "$host" -P "$port" -u awsbox "$DB" -N -e 'SELECT 1' 2>&1
}

expect_ok() {
	local label="$1" out
	shift
	for _ in $(seq 1 30); do
		out="$(client_q "$@" || true)"
		[[ "$(tail -1 <<<"$out")" == "1" ]] && {
			echo "  ok ${label}"
			return 0
		}
		# Name mismatch is a hard fail, not warm-up.
		grep -qiE 'certificate|identity|SSL' <<<"$out" && break
		sleep 2
	done
	echo "FAIL: VERIFY_IDENTITY via ${label}: ${out}" >&2
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
PORT="$(wait_available "$DB_ID")"
[[ -f "$CA_PATH" ]] || {
	echo "FAIL: missing published RDS CA at ${CA_PATH}" >&2
	exit 1
}
IMAGE="$(docker inspect -f '{{.Config.Image}}' "localemu-rds-${DB_ID}")"

docker network create "$NET" >/dev/null
docker network connect --alias "$DB_ID" "$NET" "localemu-rds-${DB_ID}"

echo "standalone mysql from a container"
expect_ok "host.docker.internal:${PORT}" --add-host host.docker.internal:host-gateway -- host.docker.internal "$PORT"
expect_ok "localemu-rds-${DB_ID}:3306" --network "$NET" -- "localemu-rds-${DB_ID}" 3306
expect_ok "${DB_ID}:3306" --network "$NET" -- "$DB_ID" 3306

echo "sad: container IP is not on the cert"
IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "localemu-rds-${DB_ID}")"
out="$(client_q --network "$NET" -- "$IP" 3306 || true)"
if [[ "$(tail -1 <<<"$out")" == "1" ]]; then
	echo "FAIL: VERIFY_IDENTITY via bare IP ${IP} unexpectedly passed" >&2
	exit 1
fi
echo "  ok rejected ${IP}"

echo "create aurora-mysql ${CLUSTER}"
aws rds create-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0 \
	--master-username awsbox \
	--master-user-password "$PASS" \
	--database-name "$DB" >/dev/null
W=""
for _ in $(seq 1 90); do
	W="$(writer_container)"
	[[ -n "$W" ]] && break
	sleep 2
done
[[ -n "$W" ]] || {
	echo "FAIL: no aurora writer container for ${CLUSTER}" >&2
	exit 1
}
W_PORT=""
for _ in $(seq 1 90); do
	W_PORT="$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Port' --output text 2>/dev/null || true)"
	[[ "$W_PORT" =~ ^[0-9]+$ ]] && break
	sleep 2
done
[[ "$W_PORT" =~ ^[0-9]+$ ]] || {
	echo "FAIL: no cluster port for ${CLUSTER}" >&2
	exit 1
}

echo "aurora writer from a container"
expect_ok "${CLUSTER}-writer:3306" --network "localemu-aurora-${CLUSTER}" -- "${CLUSTER}-writer" 3306
expect_ok "host.docker.internal:${W_PORT}" --add-host host.docker.internal:host-gateway -- host.docker.internal "$W_PORT"

echo "OK rds-mysql-tls-container-smoke"
