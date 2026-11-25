#!/usr/bin/env bash
# #763: --dev sets restart: unless-stopped on core compose services + RDS;
# ephemeral --test keeps RestartPolicy=no.
#
# Dry: compose-config assertions (always).
# Live: inspect running containers after up --dev / up --test (gate first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

ALWAYS_ON=(s3 localstack ecr-registry ecr-hostname)
PROFILE_ON=(sftp aws-redirect)

policy_for() {
	# $1=yaml blob, $2=service name → restart value or empty
	local cfg="$1" svc="$2"
	printf '%s\n' "$cfg" | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
s = (d.get('services') or {}).get('$svc') or {}
print(s.get('restart') or '')
"
}

echo "==> dry: compose-config --dev has unless-stopped on always-on core"
cfg_dev="$("$ROOT/bin/stackwrangler" compose-config dev)"
for svc in "${ALWAYS_ON[@]}"; do
	got="$(policy_for "$cfg_dev" "$svc")"
	[[ "$got" == "unless-stopped" ]] || fail "dev $svc restart=$got (want unless-stopped)"
done
echo "ok  always-on restart policies"

echo "==> dry: profile-gated sftp/aws-redirect also unless-stopped under --dev"
# Profiles are omitted from compose config unless enabled.
cfg_dev_prof="$(
	COMPOSE_PROFILES=legacy-sftp,aws-redirect \
		"$ROOT/bin/stackwrangler" compose-config dev
)"
for svc in "${PROFILE_ON[@]}"; do
	got="$(policy_for "$cfg_dev_prof" "$svc")"
	[[ "$got" == "unless-stopped" ]] || fail "dev $svc restart=$got (want unless-stopped)"
done
echo "ok  profile-gated restart policies"

echo "==> dry: compose-config --test has no unless-stopped on core services"
cfg_test="$("$ROOT/bin/stackwrangler" compose-config test)"
for svc in "${ALWAYS_ON[@]}"; do
	got="$(policy_for "$cfg_test" "$svc")"
	[[ "$got" != "unless-stopped" ]] || fail "test $svc unexpectedly restart=$got"
done
cfg_test_prof="$(
	COMPOSE_PROFILES=legacy-sftp,aws-redirect \
		"$ROOT/bin/stackwrangler" compose-config test
)"
for svc in "${PROFILE_ON[@]}"; do
	got="$(policy_for "$cfg_test_prof" "$svc")"
	[[ "$got" != "unless-stopped" ]] || fail "test $svc unexpectedly restart=$got"
done
echo "ok  test compose has no unless-stopped"

if [[ "${STACKWRANGLER_763_LIVE:-}" != "1" ]]; then
	echo "SKIP live inspect (set STACKWRANGLER_763_LIVE=1 after batch-resource-gate)"
	echo "OK: dev restart policy dry (#763)"
	exit 0
fi

inspect_restart() {
	# $1=container id/name → RestartPolicy.Name
	docker inspect "$1" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo ""
}

compose_svc_id() {
	# Resolve by compose service label for this checkout's project dir name.
	local svc="$1"
	local project
	project="$(basename "$ROOT")"
	docker ps -q \
		--filter "label=com.docker.compose.project=${project}" \
		--filter "label=com.docker.compose.service=${svc}" \
		| head -1
}

cleanup() {
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> live: up --dev → RestartPolicy unless-stopped"
"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

for svc in s3 localstack ecr-registry ecr-hostname; do
	id="$(compose_svc_id "$svc")"
	[[ -n "$id" ]] || fail "no running $svc after up --dev"
	pol="$(inspect_restart "$id")"
	[[ "$pol" == "unless-stopped" ]] || fail "dev $svc RestartPolicy=$pol (want unless-stopped)"
	echo "ok  $svc=$pol"
done

echo "==> live: create RDS → unless-stopped under PERSISTENCE=1"
DB_ID="sw763-$(date +%s)"
aws --profile local --endpoint-url http://127.0.0.1:4566 rds create-db-instance \
	--db-instance-identifier "$DB_ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username stackwrangler \
	--master-user-password 'Stackwrangler1!' \
	--allocated-storage 20 >/dev/null

RDS_CID=""
for _ in $(seq 1 90); do
	RDS_CID="$(docker ps -aq --filter "name=localemu-rds-${DB_ID}" | head -1 || true)"
	[[ -n "$RDS_CID" ]] && break
	status="$(
		aws --profile local --endpoint-url http://127.0.0.1:4566 rds describe-db-instances \
			--db-instance-identifier "$DB_ID" \
			--query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true
	)"
	[[ "$status" == "create-failed" ]] && fail "RDS create-failed for ${DB_ID}"
	sleep 2
done
[[ -n "$RDS_CID" ]] || fail "no localemu-rds-${DB_ID} container after create"
# Policy is applied at create; give the start.d hook a moment if racey.
for _ in $(seq 1 20); do
	pol="$(inspect_restart "$RDS_CID")"
	[[ "$pol" == "unless-stopped" ]] && break
	sleep 1
done
pol="$(inspect_restart "$RDS_CID")"
[[ "$pol" == "unless-stopped" ]] || fail "dev RDS ${DB_ID} RestartPolicy=$pol (want unless-stopped)"
echo "ok  RDS localemu-rds-${DB_ID}=$pol"

aws --profile local --endpoint-url http://127.0.0.1:4566 rds delete-db-instance \
	--db-instance-identifier "$DB_ID" --skip-final-snapshot >/dev/null 2>&1 || true

echo "==> live: up --test → RestartPolicy no (or empty)"
"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --test

for svc in s3 localstack ecr-registry ecr-hostname; do
	id="$(compose_svc_id "$svc")"
	[[ -n "$id" ]] || fail "no running $svc after up --test"
	pol="$(inspect_restart "$id")"
	[[ "$pol" == "no" || -z "$pol" ]] || fail "test $svc RestartPolicy=$pol (want no)"
	echo "ok  test $svc=$pol"
done

echo "OK: dev restart policy (#763)"
