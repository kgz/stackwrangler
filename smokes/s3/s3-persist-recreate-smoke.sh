#!/usr/bin/env bash
# PERSISTENCE=1: LocalEmu S3 objects + PutObject survive container recreate (#712).
# Spool/metadata live under a named volume on /var/lib/localemu; bodies restore
# after the S3 provider starts. Default compose keeps PERSISTENCE=0 (hermetic).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
BUCKET="sw-persist-s3-${TS}"
VOL="sw-persist-s3-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-persist-s3-XXXXXX.yml")"

cleanup() {
	aws --endpoint-url "$EMU" --region "$REGION" s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	rm -f "$OVERRIDE"
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${VOL}:/var/lib/localemu
EOF

echo "== persistence override (volume ${VOL}) =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null

wait_ready() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EMU/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (${code:-none})" >&2
	return 1
}
wait_ready

aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }

aws_emu s3 mb "s3://${BUCKET}" >/dev/null
echo "before-recreate" | aws_emu s3 cp - "s3://${BUCKET}/k" >/dev/null

# Flush ON_SHUTDOWN save, then recreate so /tmp is wiped but the volume stays.
"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

got="$(aws_emu s3 cp "s3://${BUCKET}/k" -)"
[[ "$got" == "before-recreate" ]] || {
	echo "FAIL: restored object body missing (got=${got:-empty})" >&2
	exit 1
}
echo "OK: GetObject after recreate"

echo "after-recreate" | aws_emu s3 cp - "s3://${BUCKET}/k2" >/dev/null
got2="$(aws_emu s3 cp "s3://${BUCKET}/k2" -)"
[[ "$got2" == "after-recreate" ]] || {
	echo "FAIL: PutObject into restored bucket failed or wrong body (got=${got2:-empty})" >&2
	exit 1
}
echo "OK: PutObject into restored bucket"

echo "OK: LocalEmu S3 persistence across recreate (#712)"
