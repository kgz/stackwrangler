#!/usr/bin/env bash
# Thin wrapper → dual-target parity check (#663). Prefer: ./bin/parity run --id scheduler-iam-arns --target local
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PARITY_TARGET=local
exec "$ROOT/smokes/parity/checks/scheduler-iam-arns.sh"
