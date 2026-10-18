#!/usr/bin/env bash
# Full e2e: SeaweedFS up → CLI parity → Playwright (console UI + CLI cross-checks).
# Usage: ./bin/e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> stack"
./bin/awsbox up --force

echo "==> CLI parity"
./bin/s3-parity.sh | tee docs/s3-parity.md

echo "==> console deps"
if [[ ! -d console/node_modules ]]; then
	(cd console && yarn install)
fi

echo "==> Playwright"
(
	cd console
	yarn playwright test
)

echo "==> e2e OK"
