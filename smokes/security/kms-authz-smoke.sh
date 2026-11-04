#!/usr/bin/env bash
# Sad: deny-user kms:Decrypt → AccessDenied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
USER="awsbox-kms-deny-${TS}"
POLICY_NAME="AwsboxDenyKmsDecrypt-${TS}"
KEEP="${AWSBOX_KMS_KEEP:-0}"
KEY_ID="" DENIED_KEY="" POLICY_ARN="" BLOB=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-kms-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
PT_FILE="${TMPDIR:-/tmp}/awsbox-kms-authz-pt-$$"
cleanup() {
	rm -f "$POLICY_DOC" "$PT_FILE"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$KEY_ID" ]] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf 'awsbox' >"$PT_FILE"
KEY_ID="$(aws kms create-key --description "awsbox-kms-authz" --query 'KeyMetadata.KeyId' --output text)"
BLOB="$(aws kms encrypt --key-id "$KEY_ID" --plaintext "fileb://${PT_FILE}" --query 'CiphertextBlob' --output text)"
rm -f "$PT_FILE"
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"kms:Decrypt","Resource":"*"}]}
EOF
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws kms decrypt --ciphertext-blob "$BLOB" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: decrypt succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' || { echo "FAIL: $OUT" >&2; exit 1; }
echo "OK: kms Decrypt AccessDenied"
echo "$OUT" | head -2
