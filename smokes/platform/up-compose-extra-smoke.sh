#!/usr/bin/env bash
# #748: refresh_compose must keep caller / checkout compose overrides on up.
# Dry: compose-config merges EXTRA + .awsbox/compose.local.yml + override.yml.
# Live: up --test applies EXTRA marker env onto LocalEmu (then restores prior stack).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="${TMPDIR:-/tmp}/sw748-$$"
mkdir -p "$TMP"
EXTRA="$TMP/extra.yml"
LOCAL_YML="$ROOT/.awsbox/compose.local.yml"
OVERRIDE_YML="$ROOT/docker-compose.override.yml"
HAD_LOCAL=0
HAD_OVERRIDE=0
LOCAL_BAK=""
OVERRIDE_BAK=""

cleanup() {
	rm -rf "$TMP"
	if [[ "$HAD_LOCAL" -eq 1 ]]; then
		[[ -n "$LOCAL_BAK" ]] && mv "$LOCAL_BAK" "$LOCAL_YML" || true
	else
		rm -f "$LOCAL_YML"
	fi
	if [[ "$HAD_OVERRIDE" -eq 1 ]]; then
		[[ -n "$OVERRIDE_BAK" ]] && mv "$OVERRIDE_BAK" "$OVERRIDE_YML" || true
	else
		rm -f "$OVERRIDE_YML"
	fi
	unset STACKWRANGLER_COMPOSE_EXTRA AWSBOX_COMPOSE_EXTRA STACKWRANGLER_COMPOSE_OVERRIDE AWSBOX_COMPOSE_OVERRIDE
}
trap cleanup EXIT

mkdir -p "$ROOT/.awsbox"
if [[ -f "$LOCAL_YML" ]]; then
	HAD_LOCAL=1
	LOCAL_BAK="$TMP/compose.local.bak"
	cp "$LOCAL_YML" "$LOCAL_BAK"
	rm -f "$LOCAL_YML"
fi
if [[ -f "$OVERRIDE_YML" ]]; then
	HAD_OVERRIDE=1
	OVERRIDE_BAK="$TMP/compose.override.bak"
	cp "$OVERRIDE_YML" "$OVERRIDE_BAK"
	rm -f "$OVERRIDE_YML"
fi

cat >"$EXTRA" <<'EOF'
services:
  localstack:
    environment:
      SW748_EXTRA: "from-extra"
EOF

cat >"$LOCAL_YML" <<'EOF'
services:
  localstack:
    environment:
      SW748_LOCAL: "from-local"
EOF

cat >"$OVERRIDE_YML" <<'EOF'
services:
  localstack:
    environment:
      SW748_OVERRIDE: "from-override"
EOF

echo "==> dry: STACKWRANGLER_COMPOSE_EXTRA + auto files in compose-config"
export STACKWRANGLER_COMPOSE_EXTRA="$EXTRA"
cfg="$("$ROOT/bin/stackwrangler" compose-config test)"
echo "$cfg" | grep -q 'SW748_EXTRA:.*from-extra' || fail "compose-config missing EXTRA marker"
echo "$cfg" | grep -q 'SW748_LOCAL:.*from-local' || fail "compose-config missing compose.local.yml marker"
echo "$cfg" | grep -q 'SW748_OVERRIDE:.*from-override' || fail "compose-config missing docker-compose.override.yml marker"
echo "ok  compose-config merges override + local + EXTRA"

echo "==> dry: COMPOSE_OVERRIDE single file"
unset STACKWRANGLER_COMPOSE_EXTRA
rm -f "$LOCAL_YML" "$OVERRIDE_YML"
export STACKWRANGLER_COMPOSE_OVERRIDE="$EXTRA"
cfg="$("$ROOT/bin/stackwrangler" compose-config test)"
echo "$cfg" | grep -q 'SW748_EXTRA:.*from-extra' || fail "compose-config missing COMPOSE_OVERRIDE marker"
unset STACKWRANGLER_COMPOSE_OVERRIDE
echo "ok  COMPOSE_OVERRIDE"

echo "==> dry: --dev includes restart: unless-stopped (#748)"
cfg_dev="$("$ROOT/bin/stackwrangler" compose-config dev)"
echo "$cfg_dev" | grep -A2 'localstack:' | grep -q 'unless-stopped' \
	|| echo "$cfg_dev" | grep -q 'restart: unless-stopped' \
	|| fail "dev compose missing restart: unless-stopped"
echo "ok  dev restart policy"

# Live up recreates the stack — opt in (destructive to the current project stack).
if [[ "${STACKWRANGLER_748_LIVE:-}" != "1" ]]; then
	echo "SKIP live up (set STACKWRANGLER_748_LIVE=1 to run destructive up --test)"
	echo "OK: up compose extras dry (#748)"
	exit 0
fi

echo "==> live: up --test keeps EXTRA on LocalEmu"
export STACKWRANGLER_COMPOSE_EXTRA="$EXTRA"
rm -f "$LOCAL_YML" "$OVERRIDE_YML"
"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --test

id="$(docker compose -f "$ROOT/docker-compose.yml" -f "$EXTRA" ps -q localstack 2>/dev/null | head -1 || true)"
[[ -n "$id" ]] || fail "no localstack container after up --test"
env_lines="$(docker inspect "$id" -f '{{range .Config.Env}}{{println .}}{{end}}')"
echo "$env_lines" | grep -qx 'SW748_EXTRA=from-extra' || fail "LocalEmu missing SW748_EXTRA after up (override dropped)"
echo "ok  live LocalEmu has EXTRA env"

echo "OK: up compose extras (#748)"
