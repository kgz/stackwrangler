#!/usr/bin/env bash
# #748: STACKWRANGLER_COMPOSE_EXTRA files stay in the compose set that up/down/reset use,
# in test and dev mode, instead of being dropped by refresh_compose. Offline: compose config only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/override.yml" <<'EOF'
services:
  localstack:
    restart: unless-stopped
    labels:
      sw748.override: "yes"
EOF

cfg() { # mode → merged compose config
	STACKWRANGLER_COMPOSE_EXTRA="$tmp/override.yml" bash -c '
		set -euo pipefail
		source "$0/bin/stackwrangler"
		refresh_compose "$1"
		"${COMPOSE[@]}" config
	' "$ROOT" "$1"
}

for mode in test dev; do
	out="$(cfg "$mode")" || fail "compose config failed in $mode mode"
	echo "$out" | grep -q 'sw748.override: "yes"' || fail "$mode: override file dropped"
	echo "$out" | grep -q 'restart: unless-stopped' || fail "$mode: override restart policy missing"
done
cfg dev | grep -q '.awsbox/dev/localemu' || fail "dev: built-in dev override lost when an extra file is added"

out="$(STACKWRANGLER_COMPOSE_EXTRA="$tmp/missing.yml" bash -c 'source "$0/bin/stackwrangler"; refresh_compose test' "$ROOT" 2>&1 || true)"
echo "$out" | grep -q 'STACKWRANGLER_COMPOSE_EXTRA file not found' || fail "missing extra file not reported: $out"

echo "ok compose-extra"
