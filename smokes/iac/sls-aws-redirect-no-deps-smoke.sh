#!/usr/bin/env bash
# #714: ensure_aws_redirect must not recreate LocalEmu (drops compose overrides).
# Happy: override PERSISTENCE=1 → same container id + env after ensure_aws_redirect.
# Sad: LocalEmu stopped → clear error; does not start localstack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

BASE="$ROOT/docker-compose.yml"
OVERRIDE="${TMPDIR:-/tmp}/sw714-compose-override-$$.yml"
VOL_NAME="sw714-smoke-localemu-$$"
EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"

compose() {
	docker compose -f "$BASE" -f "$OVERRIDE" "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	compose --profile aws-redirect down -v --remove-orphans >/dev/null 2>&1 || true
	docker compose -f "$BASE" --profile aws-redirect down -v --remove-orphans >/dev/null 2>&1 || true
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	rm -f "$OVERRIDE"
	docker volume rm "${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}_${VOL_NAME}" >/dev/null 2>&1 || true
	docker volume rm "$VOL_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${VOL_NAME}:/var/lib/localemu
    restart: unless-stopped

volumes:
  ${VOL_NAME}:
EOF

echo "==> down any prior stack for this checkout"
"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
docker compose -f "$BASE" --profile aws-redirect down -v --remove-orphans >/dev/null 2>&1 || true

echo "==> up LocalEmu (+ s3) with PERSISTENCE=1 override (no aws-redirect yet)"
# Only core services — ensure_aws_redirect brings up aws-redirect with --no-deps.
compose up -d localstack s3

wait_localemu() {
	local i id
	for i in $(seq 1 120); do
		id="$(docker compose -f "$BASE" ps -q localstack 2>/dev/null | head -1 || true)"
		if [[ -n "$id" ]] \
			&& [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" == "true" ]] \
			&& { curl -sf --max-time 1 "${EP}/_localemu/health" >/dev/null 2>&1 \
				|| curl -sf --max-time 1 "${EP}/_localstack/health" >/dev/null 2>&1; }; then
			return 0
		fi
		sleep 1
	done
	id="$(docker compose -f "$BASE" ps -aq localstack 2>/dev/null | head -1 || true)"
	[[ -n "$id" ]] && docker logs "$id" >&2 | tail -80 || true
	fail "LocalEmu did not become healthy"
}
wait_localemu
echo "ok  LocalEmu healthy"

localstack_id() {
	docker compose -f "$BASE" ps -q localstack 2>/dev/null | head -1
}

persistence_env() {
	local id="$1"
	docker inspect "$id" -f '{{range .Config.Env}}{{println .}}{{end}}' | grep '^PERSISTENCE=' || true
}

BEFORE_ID="$(localstack_id)"
[[ -n "$BEFORE_ID" ]] || fail "no localstack container after override up"
BEFORE_PERS="$(persistence_env "$BEFORE_ID")"
[[ "$BEFORE_PERS" == "PERSISTENCE=1" ]] || fail "expected PERSISTENCE=1 before ensure (got ${BEFORE_PERS:-empty})"
echo "ok  before id=${BEFORE_ID:0:12} ${BEFORE_PERS}"

call_ensure() {
	# Same path cmd_sls uses: source bin/stackwrangler and call ensure_aws_redirect.
	bash -c '
		set -euo pipefail
		ROOT="'"$ROOT"'"
		cd "$ROOT"
		# shellcheck disable=SC1091
		source "$ROOT/bin/stackwrangler"
		ensure_aws_redirect
	'
}

echo "==> ensure_aws_redirect (must not recreate LocalEmu)"
ENSURE_IP="$(call_ensure)"
[[ -n "$ENSURE_IP" ]] || fail "ensure_aws_redirect printed no IP"
AFTER_ID="$(localstack_id)"
AFTER_PERS="$(persistence_env "$AFTER_ID")"
[[ "$AFTER_ID" == "$BEFORE_ID" ]] || fail "LocalEmu recreated (before=${BEFORE_ID:0:12} after=${AFTER_ID:0:12})"
[[ "$AFTER_PERS" == "PERSISTENCE=1" ]] || fail "PERSISTENCE lost after ensure (got ${AFTER_PERS:-empty})"
echo "ok  LocalEmu id unchanged; ${AFTER_PERS}; aws-redirect at ${ENSURE_IP}"

echo "==> sad: stop LocalEmu → ensure must fail clearly (no silent start)"
docker stop "$AFTER_ID" >/dev/null
STOPPED_ID="$AFTER_ID"
set +e
ERR_OUT="$(call_ensure 2>&1 >/dev/null)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "ensure_aws_redirect succeeded while localstack stopped"
echo "$ERR_OUT" | grep -q 'localstack is not running' \
	|| fail "missing clear 'localstack is not running' message: ${ERR_OUT}"
RUNNING_NOW="$(localstack_id)"
if [[ -n "$RUNNING_NOW" ]]; then
	run_state="$(docker inspect -f '{{.State.Running}}' "$RUNNING_NOW" 2>/dev/null || true)"
	[[ "$run_state" != "true" ]] || fail "ensure started localstack while it was stopped (id=${RUNNING_NOW:0:12})"
fi
if docker inspect "$STOPPED_ID" >/dev/null 2>&1; then
	still="$(docker inspect -f '{{.State.Running}}' "$STOPPED_ID")"
	[[ "$still" == "false" ]] || fail "stopped LocalEmu is running again without explicit start"
fi
echo "ok  clear error; LocalEmu not started"

echo "OK: sls aws-redirect --no-deps preserves LocalEmu override (#714)"
