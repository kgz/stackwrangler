#!/usr/bin/env bash
# Pin RDS EngineVersion → exact Docker image; reject unknown versions (#704).
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
MYSQL_ID="awsbox-mysql-pin-${TS}"
CLUSTER="awsbox-amysql-pin-${TS}"
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
	aws rds delete-db-instance --db-instance-identifier "$MYSQL_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

container_image_for() {
	local id="$1"
	# LocalEmu names containers with the DB identifier.
	local cid
	cid="$(docker ps -aq --filter "name=${id}" | head -1)"
	[[ -n "$cid" ]] || {
		echo "FAIL: no container for ${id}" >&2
		docker ps -a --format '{{.Names}}\t{{.Image}}' | head -40 >&2 || true
		return 1
	}
	docker inspect -f '{{.Config.Image}}' "$cid"
}

echo "reject unknown mysql version"
if out="$(aws rds create-db-instance \
	--db-instance-identifier "awsbox-mysql-bad-${TS}" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0.99 \
	--master-username awsbox \
	--master-user-password 'PinTestPass1' \
	--allocated-storage 20 \
	--db-name awsbox 2>&1)"; then
	echo "FAIL: unknown version should be rejected" >&2
	echo "$out" >&2
	exit 1
fi
echo "$out" | grep -Eq 'InvalidParameterCombination|Cannot find version' || {
	echo "FAIL: expected InvalidParameterCombination / Cannot find version" >&2
	echo "$out" >&2
	exit 1
}
echo "OK unknown rejected"

echo "mysql 8.0.37 → mysql:8.0.37"
aws rds create-db-instance \
	--db-instance-identifier "$MYSQL_ID" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0.37 \
	--master-username awsbox \
	--master-user-password 'PinTestPass1' \
	--allocated-storage 20 \
	--db-name awsbox >/dev/null

img="$(container_image_for "$MYSQL_ID")"
[[ "$img" == "mysql:8.0.37" ]] || {
	echo "FAIL: want mysql:8.0.37, got ${img}" >&2
	exit 1
}
echo "OK image ${img}"

echo "aurora-mysql 8.0.mysql_aurora.3.05.2 → mysql:8.0.32"
aws rds create-db-cluster \
	--db-cluster-identifier "$CLUSTER" \
	--engine aurora-mysql \
	--engine-version 8.0.mysql_aurora.3.05.2 \
	--master-username awsbox \
	--master-user-password 'PinTestPass1' \
	--database-name awsbox >/dev/null

# Writer container is named after the cluster id.
img="$(container_image_for "$CLUSTER")"
[[ "$img" == "mysql:8.0.32" ]] || {
	echo "FAIL: want mysql:8.0.32 for aurora 3.05.2, got ${img}" >&2
	exit 1
}
echo "OK aurora image ${img}"

echo "rds-engine-version-smoke OK"
