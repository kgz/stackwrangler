#!/usr/bin/env bash
# Local wrapper for dual-side CFN path-scoped role parity (#679).
# Real side: ./smokes/parity/aws-parity-cfn-path-scoped-role.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export AWSBOX_PARITY_SKIP_REAL=1
exec "$ROOT/smokes/parity/aws-parity-cfn-path-scoped-role.sh"
