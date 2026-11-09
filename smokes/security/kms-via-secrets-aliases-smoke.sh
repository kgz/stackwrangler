#!/usr/bin/env bash
# Thin wrapper → dual-target parity check (#666). Prefer: ./bin/parity run --id kms-via-secrets-aliases --target local
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PARITY_TARGET=local
exec "$ROOT/smokes/parity/checks/kms-via-secrets-aliases.sh"
