#!/usr/bin/env bash
# Thin wrapper → dual-target parity check (#665). Prefer: ./bin/parity run --id scheduler-trust-sourcearn --target local
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PARITY_TARGET=local
exec "$ROOT/smokes/parity/checks/scheduler-trust-sourcearn.sh"
