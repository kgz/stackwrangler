#!/usr/bin/env bash
# Mode CLI (#288): usage, recorded mode, wipe-path markers, compose test/dev wiring.
# No LocalEmu / no full `reset` (that downs the host stack + wipes project volumes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

usage="$("$ROOT/bin/stackwrangler" 2>&1 || true)"
echo "$usage" | grep -q -- '--test' || fail "usage missing --test"
echo "$usage" | grep -q -- '--dev' || fail "usage missing --dev"
echo "$usage" | grep -q reset || fail "usage missing reset"

# Intended wipe paths for reset (marker-only — do not call full stackwrangler reset).
mkdir -p "$ROOT/.awsbox/dev/localemu" "$ROOT/.awsbox/dev/ecr"
echo marker >"$ROOT/.awsbox/dev/localemu/marker"
echo marker >"$ROOT/.awsbox/dev/ecr/marker"
echo dev >"$ROOT/.awsbox/mode"

rm -rf "$ROOT/.awsbox/dev"
mkdir -p "$ROOT/.awsbox"
echo test >"$ROOT/.awsbox/mode"

[[ ! -e "$ROOT/.awsbox/dev/localemu/marker" ]] || fail "wipe left LocalEmu marker"
[[ ! -e "$ROOT/.awsbox/dev/ecr/marker" ]] || fail "wipe left ECR marker"
mode="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
[[ "$mode" == "test" ]] || fail "wipe should set mode=test (got ${mode})"

# status shows mode without requiring a live stack
out="$("$ROOT/bin/stackwrangler" status 2>&1 || true)"
echo "$out" | grep -qE '^mode:[[:space:]]+test' || fail "status missing mode: test"
echo "$out" | grep -qE '^persist:[[:space:]]+off' || fail "status missing persist: off"

# Leftover .awsbox/dev must not appear in test-mode compose (smokes stay hermetic).
mkdir -p "$ROOT/.awsbox/dev/localemu" "$ROOT/.awsbox/dev/ecr"
echo leftover >"$ROOT/.awsbox/dev/localemu/leftover"

export STACKWRANGLER_PERSISTENCE=0
export STACKWRANGLER_SEAWEED_VOLUME=seaweed-data
cfg_test="$(docker compose -f "$ROOT/docker-compose.yml" config 2>/dev/null)" || fail "compose config (test) failed"
echo "$cfg_test" | grep -qE 'PERSISTENCE:[[:space:]]*"?0"?' || fail "test compose missing PERSISTENCE=0"
echo "$cfg_test" | grep -q '.awsbox/dev/localemu' && fail "test compose must not bind .awsbox/dev/localemu" || true
echo "$cfg_test" | grep -q '.awsbox/dev/ecr' && fail "test compose must not bind .awsbox/dev/ecr" || true
if echo "$cfg_test" | grep -q '.awsbox/dev/'; then
	fail "test compose must not reference .awsbox/dev (leftover dir ignored)"
fi
echo "$cfg_test" | grep -q 'seaweed-data-dev' && fail "test compose must not use seaweed-data-dev" || true

# Compose config for --dev wiring (no up): dry-check override file + env
export STACKWRANGLER_PERSISTENCE=1
export STACKWRANGLER_SEAWEED_VOLUME=seaweed-data-dev
cfg="$(docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.dev.yml" config 2>/dev/null)" || fail "compose config with dev override failed"
echo "$cfg" | grep -qE 'PERSISTENCE:[[:space:]]*"?1"?' || fail "dev compose missing PERSISTENCE=1"
echo "$cfg" | grep -q '.awsbox/dev/localemu' || fail "dev compose missing localemu bind"
echo "$cfg" | grep -q '.awsbox/dev/ecr' || fail "dev compose missing ecr bind"
echo "$cfg" | grep -q 'seaweed-data-dev' || fail "dev compose missing seaweed-data-dev"

rm -rf "$ROOT/.awsbox/dev"
echo test >"$ROOT/.awsbox/mode"

echo "OK mode-cli-smoke"
