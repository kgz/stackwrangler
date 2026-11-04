#!/usr/bin/env bash
# Resource-based policies (#193).
#   * Lambda role IAM-allowed for GetSecretValue is denied by a secret resource policy
#   * KMS key policy without IAM delegation denies that role; with delegation it works
#   * S3 bucket policy explicit deny wins over an identity Allow
#   * CMK decrypts inside Secrets Manager and SSM follow the key policy
# Error codes: AccessDeniedException (Secrets Manager, KMS, SSM), AccessDenied (S3).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""
TS="$(date +%s)"
ROLE="awsbox-rp-lambda-${TS}"
SECRET_NAME="awsbox/rp-secret-${TS}"
CMK_SECRET_NAME="awsbox/rp-cmk-${TS}"
ROLE_SECRET="awsbox/rp-role-${TS}"
BUCKET="awsbox-rp-${TS}"
PARAM="/rp/awsbox/${TS}"
KEEP="${AWSBOX_RP_KEEP:-0}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-rp-$$"
mkdir -p "$WORKDIR"
KEY_A="" KEY_B="" AK="" SK="" ST="" SECRET_ARN="" CMK_ARN=""
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
as_role() {
	AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" aws "$@"
}
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws s3api delete-object --bucket "$BUCKET" --key probe.txt >/dev/null 2>&1 || true
	aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true
	[[ -n "$SECRET_ARN" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	[[ -n "$CMK_ARN" ]] && aws secretsmanager delete-secret --secret-id "$CMK_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws secretsmanager delete-secret --secret-id "$ROLE_SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws ssm delete-parameter --name "$PARAM" >/dev/null 2>&1 || true
	[[ -n "$KEY_A" ]] && aws kms schedule-key-deletion --key-id "$KEY_A" --pending-window-in-days 7 >/dev/null 2>&1 || true
	[[ -n "$KEY_B" ]] && aws kms schedule-key-deletion --key-id "$KEY_B" --pending-window-in-days 7 >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

expect_deny() {
	local code="$1" label="$2"
	shift 2
	set +e
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; exit 1; }
	grep -q "(${code})" <<<"$out" || { echo "FAIL: ${label} expected ${code}: ${out}" >&2; exit 1; }
	echo "OK: ${label} (${code})"
}

ACCT="$(aws sts get-caller-identity --query Account --output text)"
python3 - "$WORKDIR/trust.json" "$ACCT" <<'PY'
import json, sys
path, acct = sys.argv[1], sys.argv[2]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"},
        {"Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{acct}:root"}, "Action": "sts:AssumeRole"},
    ],
}, open(path, "w"))
PY
python3 - "$WORKDIR/allow.json" <<'PY'
import json, sys
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:PutSecretValue",
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:GenerateDataKey",
            "s3:GetObject",
            "s3:ListBucket",
            "ssm:GetParameter",
            "ssm:PutParameter",
        ],
        "Resource": "*",
    }],
}, open(sys.argv[1], "w"))
PY

aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name allow --policy-document "file://${WORKDIR}/allow.json"
CREDS="$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name awsbox --output json)"
AK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
SK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
ST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"

put_key_policy() {
	local key="$1" mode="$2"
	python3 - "$WORKDIR/key.json" "$ACCT" "$ROLE_ARN" "$mode" <<'PY'
import json, sys
path, acct, role, mode = sys.argv[1:]
root = f"arn:aws:iam::{acct}:root"
if mode == "delegate":
    stmts = [{
        "Sid": "Enable IAM User Permissions",
        "Effect": "Allow",
        "Principal": {"AWS": root},
        "Action": "kms:*",
        "Resource": "*",
    }]
elif mode == "deny-encrypt":
    stmts = [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {"AWS": root},
            "Action": "kms:*",
            "Resource": "*",
        },
        {
            "Sid": "DenyRoleEncrypt",
            "Effect": "Deny",
            "Principal": {"AWS": role},
            "Action": "kms:Encrypt",
            "Resource": "*",
        },
    ]
else:
    stmts = [{
        "Sid": "RootDescribeOnly",
        "Effect": "Allow",
        "Principal": {"AWS": root},
        "Action": "kms:DescribeKey",
        "Resource": "*",
    }]
json.dump({"Version": "2012-10-17", "Statement": stmts}, open(path, "w"))
PY
	aws kms put-key-policy --key-id "$key" --policy-name default --policy "file://${WORKDIR}/key.json" >/dev/null
}

# --- KMS key policy ---
KEY_A="$(aws kms create-key --description "awsbox-rp-a" --query 'KeyMetadata.KeyId' --output text)"
printf 'awsbox' >"$WORKDIR/plain.txt"
as_role kms encrypt --key-id "$KEY_A" --plaintext "fileb://${WORKDIR}/plain.txt" --query CiphertextBlob --output text >"$WORKDIR/blob.txt"
BLOB="$(cat "$WORKDIR/blob.txt")"
RAW="$(as_role kms decrypt --ciphertext-blob "$BLOB" --key-id "$KEY_A" --query Plaintext --output text)"
[[ "$(printf '%s' "$RAW" | base64 -d)" == "awsbox" ]]
as_role kms generate-data-key --key-id "$KEY_A" --key-spec AES_256 --query KeyId --output text >/dev/null
echo "OK: kms Encrypt/Decrypt/GenerateDataKey with IAM delegation"

put_key_policy "$KEY_A" deny-encrypt
expect_deny AccessDeniedException "kms Encrypt explicit key-policy deny" \
	as_role kms encrypt --key-id "$KEY_A" --plaintext "fileb://${WORKDIR}/plain.txt"
RAW="$(as_role kms decrypt --ciphertext-blob "$BLOB" --key-id "$KEY_A" --query Plaintext --output text)"
[[ "$(printf '%s' "$RAW" | base64 -d)" == "awsbox" ]]
echo "OK: kms Decrypt still allowed when only Encrypt is denied"

put_key_policy "$KEY_A" closed
expect_deny AccessDeniedException "kms Decrypt without IAM delegation" \
	as_role kms decrypt --ciphertext-blob "$BLOB" --key-id "$KEY_A"
expect_deny AccessDeniedException "kms Encrypt without IAM delegation" \
	as_role kms encrypt --key-id "$KEY_A" --plaintext "fileb://${WORKDIR}/plain.txt"
expect_deny AccessDeniedException "kms GenerateDataKey without IAM delegation" \
	as_role kms generate-data-key --key-id "$KEY_A" --key-spec AES_256

put_key_policy "$KEY_A" delegate
RAW="$(as_role kms decrypt --ciphertext-blob "$BLOB" --query Plaintext --output text)"
[[ "$(printf '%s' "$RAW" | base64 -d)" == "awsbox" ]]
echo "OK: kms Decrypt with delegation restored (no KeyId on the request)"

# --- Secrets Manager resource policy ---
SECRET_ARN="$(aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string 's3cret' --query ARN --output text)"
VAL="$(as_role secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)"
[[ "$VAL" == "s3cret" ]]
python3 - "$WORKDIR/secret-deny.json" "$ROLE_ARN" <<'PY'
import json, sys
path, role = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "DenyLambdaRole",
        "Effect": "Deny",
        "Principal": {"AWS": role},
        "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
        "Resource": "*",
    }],
}, open(path, "w"))
PY
aws secretsmanager put-resource-policy --secret-id "$SECRET_ARN" --resource-policy "file://${WORKDIR}/secret-deny.json" >/dev/null
expect_deny AccessDeniedException "secret resource policy denies GetSecretValue" \
	as_role secretsmanager get-secret-value --secret-id "$SECRET_NAME"
expect_deny AccessDeniedException "secret resource policy denies DescribeSecret" \
	as_role secretsmanager describe-secret --secret-id "$SECRET_ARN"
aws secretsmanager delete-resource-policy --secret-id "$SECRET_ARN" >/dev/null
VAL="$(as_role secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)"
[[ "$VAL" == "s3cret" ]]
echo "OK: GetSecretValue allowed again after DeleteResourcePolicy"

# --- S3 bucket policy (LocalEmu) ---
aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-object --bucket "$BUCKET" --key probe.txt --body "$WORKDIR/plain.txt" >/dev/null
as_role s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/got.txt" >/dev/null
[[ "$(cat "$WORKDIR/got.txt")" == "awsbox" ]]
python3 - "$WORKDIR/bucket-deny.json" "$ROLE_ARN" "$BUCKET" <<'PY'
import json, sys
path, role, bucket = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "DenyLambdaRole",
        "Effect": "Deny",
        "Principal": {"AWS": role},
        "Action": ["s3:GetObject", "s3:ListBucket"],
        "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
    }],
}, open(path, "w"))
PY
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${WORKDIR}/bucket-deny.json" >/dev/null
expect_deny AccessDenied "bucket policy denies GetObject" \
	as_role s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/denied.txt"
expect_deny AccessDenied "bucket policy denies ListBucket" \
	as_role s3api list-objects-v2 --bucket "$BUCKET"

# --- Implicit CMK: Secrets Manager + SSM ---
KEY_B="$(aws kms create-key --description "awsbox-rp-b" --query 'KeyMetadata.KeyId' --output text)"
put_key_policy "$KEY_B" closed
CMK_ARN="$(aws secretsmanager create-secret --name "$CMK_SECRET_NAME" --secret-string 'cmk' --kms-key-id "$KEY_B" --query ARN --output text)"
aws ssm put-parameter --name "$PARAM" --value 'ssm' --type SecureString --key-id "$KEY_B" --overwrite >/dev/null
expect_deny AccessDeniedException "GetSecretValue denied by CMK key policy" \
	as_role secretsmanager get-secret-value --secret-id "$CMK_ARN"
expect_deny AccessDeniedException "GetParameter decryption denied by CMK key policy" \
	as_role ssm get-parameter --name "$PARAM" --with-decryption
expect_deny AccessDeniedException "PutParameter denied by CMK key policy" \
	as_role ssm put-parameter --name "$PARAM" --value 'nope' --type SecureString --key-id "$KEY_B" --overwrite
expect_deny AccessDeniedException "CreateSecret denied by CMK key policy" \
	as_role secretsmanager create-secret --name "$ROLE_SECRET" --secret-string 'nope' --kms-key-id "$KEY_B"
expect_deny AccessDeniedException "PutSecretValue denied by CMK key policy" \
	as_role secretsmanager put-secret-value --secret-id "$CMK_ARN" --secret-string 'nope'
put_key_policy "$KEY_B" delegate
VAL="$(as_role secretsmanager get-secret-value --secret-id "$CMK_ARN" --query SecretString --output text)"
[[ "$VAL" == "cmk" ]]
VAL="$(as_role ssm get-parameter --name "$PARAM" --with-decryption --query 'Parameter.Value' --output text)"
[[ "$VAL" == "ssm" ]]
as_role ssm put-parameter --name "$PARAM" --value 'ssm2' --type SecureString --key-id "$KEY_B" --overwrite >/dev/null
echo "OK: CMK delegation allows Secrets Manager and SSM"

echo "OK: resource policies"
