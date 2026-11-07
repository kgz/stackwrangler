#!/usr/bin/env bash
# Cross-account resource policies (#233): identity Allow in A is not enough for
# a secret / key / bucket in B unless B's resource policy also Allows; an
# explicit Deny on B still wins.
# Server env (restart LocalEmu after changing):
#   AWSBOX_ACCOUNT_IDS=awsbox-a=111111111111,awsbox-b=222222222222,awsbox-c=333333333333
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
KEEP="${AWSBOX_CROSS_ACCOUNT_RP_KEEP:-0}"

ACCOUNT_A="111111111111"
ACCOUNT_B="222222222222"
KEY_A="awsbox-a"
KEY_B="awsbox-b"

ROLE="awsbox-xarp-${TS}"
SECRET_NAME="awsbox/xarp-${TS}"
BUCKET="awsbox-xarp-${TS}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-xarp-$$"
mkdir -p "$WORKDIR"

ROLE_ARN="" SECRET_ARN="" KEY_ID="" KEY_ARN="" AK="" SK="" ST=""

unset AWS_PROFILE AWS_SESSION_TOKEN || true
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""

aws_as() {
	local key="$1" secret="$2" token="$3"
	shift 3
	if [[ -n "$token" ]]; then
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$token" \
			command aws --endpoint-url "$EP" --region "$REGION" "$@"
	else
		env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
			aws --endpoint-url "$EP" --region "$REGION" "$@"
	fi
}

as_role() {
	aws_as "$AK" "$SK" "$ST" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

expect_deny() {
	local code="$1" label="$2"
	shift 2
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; exit 1; }
	grep -q "(${code})" <<<"$out" || { echo "FAIL: ${label} expected ${code}: ${out}" >&2; exit 1; }
	echo "OK: ${label} (${code})"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$BUCKET" ]]; then
		aws_as "$KEY_B" "$SECRET" "" s3api delete-object --bucket "$BUCKET" --key probe.txt >/dev/null 2>&1 || true
		aws_as "$KEY_B" "$SECRET" "" s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
		aws_as "$KEY_B" "$SECRET" "" s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true
	fi
	[[ -n "$SECRET_ARN" ]] && aws_as "$KEY_B" "$SECRET" "" secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	[[ -n "$KEY_ID" ]] && aws_as "$KEY_B" "$SECRET" "" kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" iam delete-role-policy --role-name "$ROLE" --policy-name allow >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "endpoint $EP"

got="$(aws_as "$KEY_A" "$SECRET" "" sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ "$got" != "$ACCOUNT_A" ]]; then
	fail "key ${KEY_A} is account '${got:-<error>}', want ${ACCOUNT_A}.
Set AWSBOX_ACCOUNT_IDS=${KEY_A}=${ACCOUNT_A},${KEY_B}=${ACCOUNT_B},awsbox-c=333333333333 on LocalEmu, then recreate it (docs/multi-account.md)."
fi
got="$(aws_as "$KEY_B" "$SECRET" "" sts get-caller-identity --query Account --output text)"
[[ "$got" == "$ACCOUNT_B" ]] || fail "key ${KEY_B} is account ${got}, want ${ACCOUNT_B}"
echo "OK: key→account A=${ACCOUNT_A} B=${ACCOUNT_B}"

python3 - "$WORKDIR/trust.json" "$ACCOUNT_A" <<'PY'
import json, sys
path, acct = sys.argv[1], sys.argv[2]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam::{acct}:root"},
        "Action": "sts:AssumeRole",
    }],
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
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:DescribeKey",
            "kms:GenerateDataKey",
            "s3:GetObject",
            "s3:ListBucket",
        ],
        "Resource": "*",
    }],
}, open(sys.argv[1], "w"))
PY

aws_as "$KEY_A" "$SECRET" "" iam create-role --role-name "$ROLE" --assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
ROLE_ARN="$(aws_as "$KEY_A" "$SECRET" "" iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws_as "$KEY_A" "$SECRET" "" iam put-role-policy --role-name "$ROLE" --policy-name allow --policy-document "file://${WORKDIR}/allow.json"
CREDS="$(aws_as "$KEY_A" "$SECRET" "" sts assume-role --role-arn "$ROLE_ARN" --role-session-name xarp --output json)"
AK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
SK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
ST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"
got="$(as_role sts get-caller-identity --query Account --output text)"
[[ "$got" == "$ACCOUNT_A" ]] || fail "assumed role account ${got}, want ${ACCOUNT_A}"

# --- B-owned resources (no cross-account Allow yet) ---
# Cross-account GetSecretValue needs a CMK (aws/secretsmanager is same-account only).
KEY_ID="$(aws_as "$KEY_B" "$SECRET" "" kms create-key --description "awsbox-xarp" --query 'KeyMetadata.KeyId' --output text)"
KEY_ARN="$(aws_as "$KEY_B" "$SECRET" "" kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Arn' --output text)"
SECRET_ARN="$(aws_as "$KEY_B" "$SECRET" "" secretsmanager create-secret --name "$SECRET_NAME" --secret-string 'from-b' --kms-key-id "$KEY_ID" --query ARN --output text)"
aws_as "$KEY_B" "$SECRET" "" s3api create-bucket --bucket "$BUCKET" >/dev/null
printf 'from-b' >"$WORKDIR/probe.txt"
aws_as "$KEY_B" "$SECRET" "" s3api put-object --bucket "$BUCKET" --key probe.txt --body "$WORKDIR/probe.txt" >/dev/null

expect_deny AccessDeniedException "A role denied B secret without resource Allow" \
	as_role secretsmanager get-secret-value --secret-id "$SECRET_ARN"
expect_deny AccessDeniedException "A role denied B key without key-policy Allow" \
	as_role kms encrypt --key-id "$KEY_ARN" --plaintext "fileb://${WORKDIR}/probe.txt"
expect_deny AccessDenied "A role denied B bucket without bucket-policy Allow" \
	as_role s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/denied.txt"
echo "OK: no resource Allow → deny"

# --- B Allows A role on each resource ---
python3 - "$WORKDIR/secret-allow.json" "$ROLE_ARN" <<'PY'
import json, sys
path, role = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowAccountARole",
        "Effect": "Allow",
        "Principal": {"AWS": role},
        "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
        "Resource": "*",
    }],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" secretsmanager put-resource-policy --secret-id "$SECRET_ARN" --resource-policy "file://${WORKDIR}/secret-allow.json" >/dev/null

python3 - "$WORKDIR/key.json" "$ACCOUNT_B" "$ROLE_ARN" <<'PY'
import json, sys
path, acct_b, role = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam::{acct_b}:root"},
            "Action": "kms:*",
            "Resource": "*",
        },
        {
            "Sid": "AllowAccountARole",
            "Effect": "Allow",
            "Principal": {"AWS": role},
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:GenerateDataKey",
            ],
            "Resource": "*",
        },
    ],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "file://${WORKDIR}/key.json" >/dev/null

python3 - "$WORKDIR/bucket-allow.json" "$ROLE_ARN" "$BUCKET" <<'PY'
import json, sys
path, role, bucket = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowAccountARole",
        "Effect": "Allow",
        "Principal": {"AWS": role},
        "Action": ["s3:GetObject", "s3:ListBucket"],
        "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
    }],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${WORKDIR}/bucket-allow.json" >/dev/null

VAL="$(as_role secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)"
[[ "$VAL" == "from-b" ]] || fail "GetSecretValue got '${VAL}'"
BLOB="$(as_role kms encrypt --key-id "$KEY_ARN" --plaintext "fileb://${WORKDIR}/probe.txt" --query CiphertextBlob --output text)"
[[ -n "$BLOB" ]] || fail "kms Encrypt returned empty blob"
as_role s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/got.txt" >/dev/null
[[ "$(cat "$WORKDIR/got.txt")" == "from-b" ]] || fail "GetObject body mismatch"
echo "OK: identity + resource Allow → succeed"

# --- Explicit Deny on B still wins ---
python3 - "$WORKDIR/secret-deny.json" "$ROLE_ARN" <<'PY'
import json, sys
path, role = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowAccountARole",
            "Effect": "Allow",
            "Principal": {"AWS": role},
            "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
            "Resource": "*",
        },
        {
            "Sid": "DenyAccountARole",
            "Effect": "Deny",
            "Principal": {"AWS": role},
            "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
            "Resource": "*",
        },
    ],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" secretsmanager put-resource-policy --secret-id "$SECRET_ARN" --resource-policy "file://${WORKDIR}/secret-deny.json" >/dev/null

python3 - "$WORKDIR/key-deny.json" "$ACCOUNT_B" "$ROLE_ARN" <<'PY'
import json, sys
path, acct_b, role = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam::{acct_b}:root"},
            "Action": "kms:*",
            "Resource": "*",
        },
        {
            "Sid": "AllowAccountARole",
            "Effect": "Allow",
            "Principal": {"AWS": role},
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:GenerateDataKey",
            ],
            "Resource": "*",
        },
        {
            "Sid": "DenyAccountARoleEncrypt",
            "Effect": "Deny",
            "Principal": {"AWS": role},
            "Action": "kms:Encrypt",
            "Resource": "*",
        },
    ],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "file://${WORKDIR}/key-deny.json" >/dev/null

python3 - "$WORKDIR/bucket-deny.json" "$ROLE_ARN" "$BUCKET" <<'PY'
import json, sys
path, role, bucket = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowAccountARole",
            "Effect": "Allow",
            "Principal": {"AWS": role},
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
        },
        {
            "Sid": "DenyAccountARole",
            "Effect": "Deny",
            "Principal": {"AWS": role},
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
        },
    ],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${WORKDIR}/bucket-deny.json" >/dev/null

expect_deny AccessDeniedException "B secret explicit Deny beats Allow" \
	as_role secretsmanager get-secret-value --secret-id "$SECRET_ARN"
expect_deny AccessDeniedException "B key explicit Deny beats Allow" \
	as_role kms encrypt --key-id "$KEY_ARN" --plaintext "fileb://${WORKDIR}/probe.txt"
expect_deny AccessDenied "B bucket explicit Deny beats Allow" \
	as_role s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/denied2.txt"
echo "OK: explicit Deny on B wins"

# --- Root bypasses IAM evaluate: gate must still be action-specific ---
ROOT_A="arn:aws:iam::${ACCOUNT_A}:root"
python3 - "$WORKDIR/bucket-list-only.json" "$ROOT_A" "$BUCKET" <<'PY'
import json, sys
path, root, bucket = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowARootListOnly",
        "Effect": "Allow",
        "Principal": {"AWS": root},
        "Action": "s3:ListBucket",
        "Resource": f"arn:aws:s3:::{bucket}",
    }],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${WORKDIR}/bucket-list-only.json" >/dev/null
aws_as "$KEY_A" "$SECRET" "" s3api head-bucket --bucket "$BUCKET" >/dev/null
aws_as "$KEY_A" "$SECRET" "" s3api list-objects-v2 --bucket "$BUCKET" --query 'KeyCount' --output text >/dev/null
expect_deny AccessDenied "A root GetObject denied when only ListBucket Allowed" \
	aws_as "$KEY_A" "$SECRET" "" s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/root-denied.txt"
echo "OK: Root ListBucket Allow does not open GetObject"

python3 - "$WORKDIR/bucket-root-deny-get.json" "$ROOT_A" "$BUCKET" <<'PY'
import json, sys
path, root, bucket = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowARoot",
            "Effect": "Allow",
            "Principal": {"AWS": root},
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
        },
        {
            "Sid": "DenyARootGetObject",
            "Effect": "Deny",
            "Principal": {"AWS": root},
            "Action": "s3:GetObject",
            "Resource": f"arn:aws:s3:::{bucket}/*",
        },
    ],
}, open(path, "w"))
PY
aws_as "$KEY_B" "$SECRET" "" s3api put-bucket-policy --bucket "$BUCKET" --policy "file://${WORKDIR}/bucket-root-deny-get.json" >/dev/null
aws_as "$KEY_A" "$SECRET" "" s3api list-objects-v2 --bucket "$BUCKET" --query 'KeyCount' --output text >/dev/null
expect_deny AccessDenied "A root GetObject denied by explicit Deny despite Allow" \
	aws_as "$KEY_A" "$SECRET" "" s3api get-object --bucket "$BUCKET" --key probe.txt "$WORKDIR/root-denied2.txt"
echo "OK: Root explicit GetObject Deny wins"

echo "cross-account resource policy smoke passed"
