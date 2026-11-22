#!/usr/bin/env bash
# Prove-coverage classifier (#676): matrix cell status vs descriptive prose,
# plus freeish cost-line detection used for uncatalogued free-ci denom.
# Offline — no LocalEmu / Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

"$ROOT/bin/coverage-report.sh" --self-test

echo "OK coverage-report-smoke"
