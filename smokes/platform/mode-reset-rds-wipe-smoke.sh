#!/usr/bin/env bash
# #200: `reset` actually removes localemu-rds-* containers and localemu-rds-*-data volumes.
# Hermetic — no LocalEmu up. Uses STACKWRANGLER_RESET_RDS_ONLY=1 so Seaweed/.awsbox stay untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TS="$(date +%s)"
CID="localemu-rds-smokewipe-${TS}"
VOL="localemu-rds-smokewipe-${TS}-data"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	docker rm -f "$CID" >/dev/null 2>&1 || true
	docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail "docker required"

echo "==> create dummy RDS container + data volume"
docker volume create "$VOL" >/dev/null
docker run -d --name "$CID" -v "${VOL}:/var/lib/postgresql/data" alpine:3.20 sleep 3600 >/dev/null

docker inspect "$CID" >/dev/null || fail "fixture container missing"
docker volume inspect "$VOL" >/dev/null || fail "fixture volume missing"

echo "==> reset (RDS backends only)"
STACKWRANGLER_RESET_RDS_ONLY=1 "$ROOT/bin/stackwrangler" reset

docker inspect "$CID" >/dev/null 2>&1 && fail "reset left container ${CID}"
docker volume inspect "$VOL" >/dev/null 2>&1 && fail "reset left volume ${VOL}"

# Full reset path must still call the same wipe (string presence on the shared helper).
grep -qF 'wipe_localemu_rds_backends' "$ROOT/bin/stackwrangler" || fail "cmd_reset missing wipe_localemu_rds_backends"

echo "OK mode-reset-rds-wipe-smoke"
