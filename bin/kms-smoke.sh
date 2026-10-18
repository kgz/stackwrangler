#!/usr/bin/env bash
# Happy: create key → encrypt/decrypt → schedule delete.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
KEEP="${AWSBOX_KMS_KEEP:-0}"
KEY_ID=""
PT_FILE="${TMPDIR:-/tmp}/awsbox-kms-pt-$$"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$PT_FILE"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$KEY_ID" ]] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf 'awsbox' >"$PT_FILE"
KEY_ID="$(aws kms create-key --description "awsbox-kms-smoke" --query 'KeyMetadata.KeyId' --output text)"
BLOB="$(aws kms encrypt --key-id "$KEY_ID" --plaintext "fileb://${PT_FILE}" --query 'CiphertextBlob' --output text)"
RAW="$(aws kms decrypt --ciphertext-blob "$BLOB" --query 'Plaintext' --output text)"
DECODED="$(echo "$RAW" | base64 -d)"
[[ "$DECODED" == "awsbox" ]]
echo "OK: kms encrypt/decrypt (${KEY_ID})"
