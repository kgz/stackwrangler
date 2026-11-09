#!/usr/bin/env bash
# Thin wrapper → dual-target parity check (#664). Prefer: ./bin/parity run --id ec2-vpc-condition-keys --target local
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PARITY_TARGET=local
exec "$ROOT/smokes/parity/checks/ec2-vpc-condition-keys.sh"
