#!/usr/bin/env bash
# Assert SeaweedFS (:8333) and LocalEmu S3 (:4566) are separate stores.
# Create on one → must NOT be visible on the other. Exit 0 only when split holds.
# Docs: docs/s3-backends.md  ·  #143
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

SEA="${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}"
EMU="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
BUCKET_SEA="awsbox-dual-sea-${TS}"
BUCKET_EMU="awsbox-dual-emu-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws_sea() { command aws --endpoint-url "$SEA" --region "$REGION" "$@"; }
aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }

cleanup() {
	aws_sea s3 rb "s3://${BUCKET_SEA}" --force >/dev/null 2>&1 || true
	aws_emu s3 rb "s3://${BUCKET_EMU}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws_sea s3 mb "s3://${BUCKET_SEA}" >/dev/null
aws_emu s3 mb "s3://${BUCKET_EMU}" >/dev/null

# Seaweed bucket must not head on LocalEmu
set +e
OUT_EMU="$(aws_emu s3api head-bucket --bucket "$BUCKET_SEA" 2>&1)"
RC_EMU=$?
set -e
if [[ "$RC_EMU" -eq 0 ]]; then
	echo "FAIL: Seaweed bucket ${BUCKET_SEA} visible on LocalEmu ${EMU} — stores are not split" >&2
	exit 1
fi

# LocalEmu bucket must not head on Seaweed
set +e
OUT_SEA="$(aws_sea s3api head-bucket --bucket "$BUCKET_EMU" 2>&1)"
RC_SEA=$?
set -e
if [[ "$RC_SEA" -eq 0 ]]; then
	echo "FAIL: LocalEmu bucket ${BUCKET_EMU} visible on Seaweed ${SEA} — stores are not split" >&2
	exit 1
fi

echo "OK: dual S3 split holds (Seaweed ${SEA} ≠ LocalEmu ${EMU})"
echo "  sea-only=${BUCKET_SEA} (absent on emu: $(echo "$OUT_EMU" | head -1 | tr '\n' ' '))"
echo "  emu-only=${BUCKET_EMU} (absent on sea: $(echo "$OUT_SEA" | head -1 | tr '\n' ' '))"
