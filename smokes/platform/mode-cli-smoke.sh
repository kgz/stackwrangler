#!/usr/bin/env bash
# Mode CLI (#288): usage, recorded mode, reset wipe — no LocalEmu required.
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

mkdir -p "$ROOT/.awsbox/dev/localemu" "$ROOT/.awsbox/dev/ecr"
echo marker >"$ROOT/.awsbox/dev/localemu/marker"
echo marker >"$ROOT/.awsbox/dev/ecr/marker"
echo dev >"$ROOT/.awsbox/mode"

"$ROOT/bin/stackwrangler" reset

[[ ! -e "$ROOT/.awsbox/dev/localemu/marker" ]] || fail "reset left LocalEmu marker"
[[ ! -e "$ROOT/.awsbox/dev/ecr/marker" ]] || fail "reset left ECR marker"
mode="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
[[ "$mode" == "test" ]] || fail "reset should set mode=test (got ${mode})"

# status shows mode without requiring a live stack
out="$("$ROOT/bin/stackwrangler" status 2>&1 || true)"
echo "$out" | grep -qE '^mode:[[:space:]]+test' || fail "status missing mode: test"
echo "$out" | grep -qE '^persist:[[:space:]]+off' || fail "status missing persist: off"

# Compose config for --dev wiring (no up): dry-check override file + env
export STACKWRANGLER_PERSISTENCE=1
export STACKWRANGLER_SEAWEED_VOLUME=seaweed-data-dev
cfg="$(docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.dev.yml" config 2>/dev/null)" || fail "compose config with dev override failed"
echo "$cfg" | grep -qE 'PERSISTENCE:[[:space:]]*"?1"?' || fail "dev compose missing PERSISTENCE=1"
echo "$cfg" | grep -q '.awsbox/dev/localemu' || fail "dev compose missing localemu bind"
echo "$cfg" | grep -q '.awsbox/dev/ecr' || fail "dev compose missing ecr bind"
echo "$cfg" | grep -q 'seaweed-data-dev' || fail "dev compose missing seaweed-data-dev"

echo "OK mode-cli-smoke"
