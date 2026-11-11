#!/usr/bin/env bash
# Local wrapper for dual-side SG prefix-list Description parity (#682).
# Real side: ./smokes/parity/aws-parity-sg-prefixlist-description.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export AWSBOX_PARITY_SKIP_REAL=1
exec "$ROOT/smokes/parity/aws-parity-sg-prefixlist-description.sh"
