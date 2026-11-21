#!/usr/bin/env bash
# v0.0.8 dual-target parity driver (#768 / #769).
# Usage:
#   ./smokes/parity/aws-parity-v008.sh --target local
#   ./smokes/parity/aws-parity-v008.sh --target both --approve-cost
#
# Cost (real, ~15m then teardown): ALB + ≤2 Fargate 0.25vCPU ≈ $0.02–0.05.
# Residual: none if torn down. Cap: $0.50. No KMS / RDS / NAT.
# Docs: docs/aws-parity-v008.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="local"
APPROVE=0
KEEP=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--target)
		TARGET="${2:?}"
		shift 2
		;;
	--target=*)
		TARGET="${1#*=}"
		shift
		;;
	--approve-cost)
		APPROVE=1
		shift
		;;
	--keep)
		KEEP=1
		shift
		;;
	-h | --help)
		sed -n '2,12p' "$0"
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

echo "======== v0.0.8 parity ========"
echo "target=${TARGET}"
echo "est real cost: ~\$0.02–0.05 for ~15m (ALB + Fargate); residual none if torn down"
echo "local-only tickets (#747/#749/#750/#753/#754/#764/#765/#770/#771): see docs/aws-parity-v008.md"
echo

ARGS=(run --suite v008 --target "$TARGET")
[[ "$APPROVE" == "1" ]] && ARGS+=(--approve-cost)
[[ "$KEEP" == "1" ]] && ARGS+=(--keep)
exec "$ROOT/bin/parity" "${ARGS[@]}"
