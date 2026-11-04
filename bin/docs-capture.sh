#!/usr/bin/env bash
# Capture product console screenshots into docs/assets/console/.
# Requires a healthy console (default http://127.0.0.1:3000). Does not start Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONSOLE_URL="${AWSBOX_CONSOLE_URL:-${STACKWRANGLER_CONSOLE_URL:-http://127.0.0.1:3000}}"
OUT="$ROOT/docs/assets/console"
mkdir -p "$OUT"

if ! curl -sf -o /dev/null --max-time 3 "$CONSOLE_URL/"; then
	echo "error: console not reachable at $CONSOLE_URL" >&2
	echo "Start with: ./bin/stackwrangler up && ./bin/stackwrangler console" >&2
	exit 1
fi

echo "==> docs-capture → $OUT (console $CONSOLE_URL)"
export AWSBOX_CONSOLE_URL="$CONSOLE_URL"
export DOCS_CAPTURE_OUT="$OUT"

cd "$ROOT/console"
# Reuse existing server; do not spawn a second vite for capture.
yarn playwright test --project=docs-capture "$@"
echo "ok: shots under docs/assets/console/ (see docs/console-shots.md)"
