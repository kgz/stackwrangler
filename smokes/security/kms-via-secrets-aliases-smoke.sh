#!/usr/bin/env bash
# Secrets Manager → KMS ViaService + ResourceAliases (#666).
# Happy: GetSecretValue allowed when kms:ViaService=secretsmanager.<region>
#        and ForAnyValue kms:ResourceAliases matches the CMK alias.
# Sad: wrong alias denied; direct kms:Decrypt denied (no ViaService).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
ACCOUNT="${STACKWRANGLER_ACCOUNT_ID:-${AWSBOX_ACCOUNT_ID:-000000000000}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""
TS="$(date +%s)"
KEEP="${AWSBOX_KMS_VIA_SECRETS_KEEP:-0}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-kms-via-sec-$$"
mkdir -p "$WORKDIR"
ALIAS="alias/local-app-signing-${TS}"
WRONG_ALIAS="alias/other-signing-${TS}"
SECRET_NAME="awsbox/kms-via-${TS}"
USER="awsbox-kms-via-sec-${TS}"
POLICY_NAME="AwsboxKmsViaSec-${TS}"
WRONG_POLICY_NAME="AwsboxKmsViaSecWrong-${TS}"
KEY_ID="" SECRET_ARN="" POLICY_ARN="" WRONG_POLICY_ARN="" USER_KEY=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
as_user() {
	AWS_ACCESS_KEY_ID="$USER_KEY" AWS_SECRET_ACCESS_KEY="$USER_SECRET" aws "$@"
}

cleanup() {
	rm -rf "$WORKDIR"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SECRET_ARN" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	[[ -n "$USER_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$WRONG_POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$WRONG_POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$WRONG_POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$WRONG_POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	aws kms delete-alias --alias-name "$ALIAS" >/dev/null 2>&1 || true
	[[ -n "$KEY_ID" ]] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect_deny() {
	local label="$1"
	shift
	set +e
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; exit 1; }
	echo "$out" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' \
		|| { echo "FAIL: ${label}: ${out}" >&2; exit 1; }
	echo "OK: ${label}"
}

VIA="secretsmanager.${REGION}.amazonaws.com"

KEY_ID="$(aws kms create-key --description "awsbox-kms-via-sec-${TS}" --query 'KeyMetadata.KeyId' --output text)"
KEY_ARN="$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Arn' --output text)"
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID" >/dev/null

SECRET_ARN="$(aws secretsmanager create-secret \
	--name "$SECRET_NAME" \
	--secret-string 'kms-via-secret' \
	--kms-key-id "$ALIAS" \
	--query 'ARN' --output text)"

# Deny resource must be the UUID key ARN (not key/alias/...).
DESCRIBE_KMS="$(aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --query 'KmsKeyId' --output text || true)"
echo "secret KmsKeyId stored as: ${DESCRIBE_KMS}"

python3 - "$WORKDIR/user-policy.json" "$VIA" "$ALIAS" <<'PY'
import json, sys
path, via, alias = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {
                "StringEquals": {"kms:ViaService": via},
                "ForAnyValue:StringEquals": {"kms:ResourceAliases": alias},
            },
        },
    ],
}, open(path, "w"))
PY
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${WORKDIR}/user-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
USER_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$KEYS_JSON")"
USER_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$KEYS_JSON")"

GOT="$(as_user secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query 'SecretString' --output text)"
[[ "$GOT" == "kms-via-secret" ]]
echo "OK: GetSecretValue allowed with kms:ViaService=${VIA} and kms:ResourceAliases=${ALIAS}"

# Deny message must name key/<uuid>, not key/alias/...
set +e
DENY_OUT="$(as_user kms decrypt --ciphertext-blob "$(
	PT="$WORKDIR/pt.bin"
	printf 'direct' >"$PT"
	aws kms encrypt --key-id "$KEY_ID" --plaintext "fileb://${PT}" --query 'CiphertextBlob' --output text
)" 2>&1)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || { echo "FAIL: direct Decrypt succeeded" >&2; exit 1; }
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized' \
	|| { echo "FAIL: direct Decrypt: ${DENY_OUT}" >&2; exit 1; }
if ! echo "$DENY_OUT" | grep -q "key/${KEY_ID}" && ! echo "$DENY_OUT" | grep -q "$KEY_ARN"; then
	echo "FAIL: deny resource not key ARN: ${DENY_OUT}" >&2
	exit 1
fi
if echo "$DENY_OUT" | grep -q "key/alias/"; then
	echo "FAIL: deny still uses key/alias/: ${DENY_OUT}" >&2
	exit 1
fi
echo "OK: direct kms:Decrypt denied without ViaService (resource is key ARN)"

# Wrong alias: swap identity policy to a different ResourceAliases value.
aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
python3 - "$WORKDIR/wrong-policy.json" "$VIA" "$WRONG_ALIAS" <<'PY'
import json, sys
path, via, alias = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {
                "StringEquals": {"kms:ViaService": via},
                "ForAnyValue:StringEquals": {"kms:ResourceAliases": alias},
            },
        },
    ],
}, open(path, "w"))
PY
WRONG_POLICY_ARN="$(aws iam create-policy --policy-name "$WRONG_POLICY_NAME" --policy-document "file://${WORKDIR}/wrong-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$WRONG_POLICY_ARN" >/dev/null
expect_deny "GetSecretValue denied when kms:ResourceAliases mismatches" \
	as_user secretsmanager get-secret-value --secret-id "$SECRET_ARN"

echo "OK: kms ViaService + ResourceAliases secrets smoke"
