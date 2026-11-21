#!/usr/bin/env bash
# Assert org-path S3 brain is LocalEmu (:4566):
#   put via IAM endpoint → visible via managed profile `local` (temp AWS files)
# SeaweedFS (:8333) may still run for optional parity but must NOT see the bucket.
# Docs: docs/s3-backends.md  ·  #162
# Legacy name: s3-dual-endpoint-smoke.sh (shim).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

SEA="${STACKWRANGLER_ENDPOINT:-${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}}"
EMU="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
BUCKET="sw-org-s3-${TS}"
OBJ_KEY="org-path.txt"
OBJ_BODY="org-path-brain-${TS}"

# Hermetic profile files (local-emu-env points ~/.aws at /dev/null).
AWS_DIR="$(mktemp -d /tmp/sw-org-s3-profile.XXXXXX)"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_DIR}/credentials"
export AWS_CONFIG_FILE="${AWS_DIR}/config"
touch "$AWS_SHARED_CREDENTIALS_FILE" "$AWS_CONFIG_FILE"

aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }
aws_sea() { command aws --endpoint-url "$SEA" --region "$REGION" "$@"; }

cleanup() {
	aws_emu s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	rm -rf "$AWS_DIR"
}
trap cleanup EXIT

# Write the same managed profile shape as `stackwrangler up`.
"$ROOT/bin/stackwrangler-profile" write --force >/dev/null

# Contract: profile local s3.endpoint_url must be LocalEmu, not Seaweed.
s3_ep="$(awk '
	$0 == "[services stackwrangler]" { in_svc=1; next }
	in_svc && /^\[/ { exit }
	in_svc && $1 == "s3" { in_s3=1; next }
	in_s3 && /^[[:space:]]*endpoint_url/ {
		sub(/^.*=[[:space:]]*/, "")
		print
		exit
	}
' "$AWS_CONFIG_FILE")"
if [[ "$s3_ep" != "$EMU" ]]; then
	echo "FAIL: profile local s3.endpoint_url is '${s3_ep}', expected org-path brain ${EMU}" >&2
	exit 1
fi

aws_emu s3 mb "s3://${BUCKET}" >/dev/null
printf '%s' "$OBJ_BODY" | aws_emu s3 cp - "s3://${BUCKET}/${OBJ_KEY}" >/dev/null

# Profile local (services → LocalEmu) must see the object.
got="$(aws --profile local s3 cp "s3://${BUCKET}/${OBJ_KEY}" -)"
if [[ "$got" != "$OBJ_BODY" ]]; then
	echo "FAIL: profile local did not read LocalEmu object (got '${got}')" >&2
	exit 1
fi

# Seaweed must not have the bucket (silent cross-wire would make this succeed).
set +e
OUT_SEA="$(aws_sea s3api head-bucket --bucket "$BUCKET" 2>&1)"
RC_SEA=$?
set -e
if [[ "$RC_SEA" -eq 0 ]]; then
	echo "FAIL: LocalEmu bucket ${BUCKET} visible on Seaweed ${SEA} — org path silently cross-wired" >&2
	exit 1
fi

echo "OK: org-path S3 brain is LocalEmu ${EMU}"
echo "  profile s3.endpoint_url=${s3_ep}"
echo "  bucket=${BUCKET} visible via aws --profile local"
echo "  absent on Seaweed ${SEA}: $(echo "$OUT_SEA" | head -1 | tr '\n' ' ')"
