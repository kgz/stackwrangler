#!/usr/bin/env bash
# #746: image-mode ensure_env + profile write leave bind-mounted host files owned
# by the mount-point user (not root), credentials mode 0600, and host-editable.
# Builds only the orchestrator image — no compose stack / LocalEmu.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="${STACKWRANGLER_SMOKE_TAG:-746-host-owned}"
DATA="${STACKWRANGLER_SMOKE_HOME:-$(mktemp -d /tmp/stackwrangler-host-owned-data.XXXXXX)}"
AWS="${STACKWRANGLER_SMOKE_AWS:-$(mktemp -d /tmp/stackwrangler-host-owned-aws.XXXXXX)}"
IMAGE="stackwrangler:${TAG}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	rm -rf "$DATA" "$AWS" 2>/dev/null || true
}
trap cleanup EXIT

[[ "$(id -u)" -ne 0 ]] || fail "smoke must run as a non-root host user"

rm -rf "${DATA:?}/"* "${AWS:?}/"* 2>/dev/null || true
mkdir -p "$DATA" "$AWS"

# Pre-existing user-owned credentials (world-readable on purpose) — rewrite must
# not leave them root-owned, and should tighten mode to 0600.
printf '%s\n' '[default]' 'aws_access_key_id = preexisting' 'aws_secret_access_key = preexisting' \
	>"$AWS/credentials"
chmod 644 "$AWS/credentials"
HOST_UG="$(stat -c '%u:%g' "$DATA")"
[[ "$(stat -c '%u:%g' "$AWS")" == "$HOST_UG" ]] || fail "aws dir owner mismatch before run"

docker build -q -f "$ROOT/docker/Dockerfile" --build-arg "IMAGE_VERSION=${TAG}" \
	-t "$IMAGE" "$ROOT" >/dev/null

# Run image CLI pieces as root against host bind mounts (same shape as README).
docker run --rm --entrypoint bash \
	-v "${DATA}:/data" \
	-v "${AWS}:/root/.aws" \
	-e STACKWRANGLER_DATA=/data \
	"$IMAGE" \
	-c '
		set -euo pipefail
		# Load image CLI without invoking main.
		eval "$(sed "/^main \"\$@\"$/d" /usr/local/bin/stackwrangler)"
		ensure_env
		write_profile --force
	'

assert_owned() {
	local f="$1"
	[[ -f "$f" ]] || fail "missing $f"
	local ug
	ug="$(stat -c '%u:%g' "$f")"
	[[ "$ug" == "$HOST_UG" ]] || fail "$f owned by $ug (want $HOST_UG)"
}

assert_owned "$DATA/.env"
assert_owned "$DATA/README.txt"
assert_owned "$AWS/config"
assert_owned "$AWS/credentials"

mode="$(stat -c '%a' "$AWS/credentials")"
[[ "$mode" == "600" ]] || fail "credentials mode $mode (want 600)"

grep -q '^\[default\]' "$AWS/credentials" || fail "pre-existing [default] profile was dropped"
grep -q '^\[local\]' "$AWS/credentials" || fail "managed [local] profile missing"

# Host user can edit without sudo (the original bug).
printf '\n# smoke-edit\n' >>"$AWS/credentials" || fail "host cannot append credentials"
printf '\n# smoke-edit\n' >>"$DATA/.env" || fail "host cannot append .env"

echo "OK docker-host-owned-smoke (uid:gid ${HOST_UG}, credentials 0600)"
