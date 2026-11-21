#!/usr/bin/env bash
# #754: the boot.d hook hands /var/lib/localemu to the localemu user (uid 1000) when the host
# created it as someone else (root, CI, another uid), and leaves it alone when already owned.
# Runs the hook in a throwaway container; does not touch .awsbox/dev.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/localemu-patches/init/boot.d/01-dev-state-owner.py"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[[ -f "$HOOK" ]] || fail "missing $HOOK"
out="$(docker run --rm -v "$HOOK:/hook.py:ro" python:3.12-alpine sh -ec '
	adduser -D -u 1000 localemu
	mkdir -p /var/lib/localemu/logs && touch /var/lib/localemu/logs/x  # root-owned, like a root CLI
	python3 /hook.py
	stat -c "%u %n" /var/lib/localemu /var/lib/localemu/logs /var/lib/localemu/logs/x
	su localemu -s /bin/sh -c "mkdir /var/lib/localemu/lib" && echo writable
')"
echo "$out" | grep -q '^1000 /var/lib/localemu$' || fail "state dir not handed to uid 1000: $out"
echo "$out" | grep -q '^1000 /var/lib/localemu/logs/x$' || fail "nested files not handed over: $out"
echo "$out" | grep -q '^writable$' || fail "localemu still cannot write: $out"

echo "ok dev-state-owner"
