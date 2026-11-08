#!/usr/bin/env bash
# Service-origin IAM condition keys (#223).
# Happy: S3 SSE-KMS Put/Get allowed when kms:ViaService / aws:SourceArn match;
#        EC2 RunInstances with IamInstanceProfile when PassedToService=ec2.
# Sad: direct kms:Decrypt denied without ViaService; key policy SourceArn mismatch
#      denies S3 path; PassRole to events denied when only ec2 is allowed.
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
KEEP="${AWSBOX_SVC_ORIGIN_KEEP:-0}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-svc-origin-$$"
mkdir -p "$WORKDIR"
USER="awsbox-via-${TS}"
POLICY_NAME="AwsboxViaService-${TS}"
BUCKET="awsbox-via-${TS}"
KEY_ID="" POLICY_ARN="" USER_KEY="" IID=""
PASS_ROLE="awsbox-via-pass-${TS}"
EC2_USER="awsbox-via-ec2-user-${TS}"
EC2_POLICY="AwsboxViaEc2Pass-${TS}"
EC2_POLICY_ARN="" EC2_KEY=""
BODY="$WORKDIR/plain.txt"
OUT="$WORKDIR/got.txt"
printf 'awsbox-via-service' >"$BODY"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
as_user() {
	AWS_ACCESS_KEY_ID="$USER_KEY" AWS_SECRET_ACCESS_KEY="$USER_SECRET" aws "$@"
}
as_ec2_user() {
	AWS_ACCESS_KEY_ID="$EC2_KEY" AWS_SECRET_ACCESS_KEY="$EC2_SECRET" aws "$@"
}

cleanup() {
	rm -rf "$WORKDIR"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$IID" ]] && aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true
	aws s3api delete-object --bucket "$BUCKET" --key probe.txt >/dev/null 2>&1 || true
	aws s3api delete-object --bucket "$BUCKET" --key probe2.txt >/dev/null 2>&1 || true
	aws s3api delete-object --bucket "$BUCKET" --key probe3.txt >/dev/null 2>&1 || true
	aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true
	[[ -n "$KEY_ID" ]] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
	[[ -n "$USER_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	[[ -n "$EC2_KEY" ]] && aws iam delete-access-key --user-name "$EC2_USER" --access-key-id "$EC2_KEY" >/dev/null 2>&1 || true
	[[ -n "$EC2_POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$EC2_USER" --policy-arn "$EC2_POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$EC2_POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$EC2_POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$EC2_USER" >/dev/null 2>&1 || true
	aws iam remove-role-from-instance-profile --instance-profile-name "$PASS_ROLE" --role-name "$PASS_ROLE" >/dev/null 2>&1 || true
	aws iam delete-instance-profile --instance-profile-name "$PASS_ROLE" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$PASS_ROLE" >/dev/null 2>&1 || true
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

VIA="s3.${REGION}.amazonaws.com"
BUCKET_ARN="arn:aws:s3:::${BUCKET}"

# --- CMK: identity Allow only via S3; key policy requires SourceArn/SourceAccount ---
KEY_ID="$(aws kms create-key --description "awsbox-via-${TS}" --query 'KeyMetadata.KeyId' --output text)"
KEY_ARN="$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Arn' --output text)"
# Default create-key policy already delegates to account root / IAM. Leave it.

python3 - "$WORKDIR/user-policy.json" "$KEY_ARN" "$VIA" <<'PY'
import json, sys
path, key_arn, via = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["s3:CreateBucket", "s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
            "Resource": key_arn,
            "Condition": {"StringEquals": {"kms:ViaService": via}},
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

# Direct Decrypt must fail (no kms:ViaService on the request).
PT_FILE="$WORKDIR/pt.bin"
printf 'direct' >"$PT_FILE"
BLOB="$(aws kms encrypt --key-id "$KEY_ID" --plaintext "fileb://${PT_FILE}" --query 'CiphertextBlob' --output text)"
expect_deny "direct kms:Decrypt denied without ViaService" \
	as_user kms decrypt --ciphertext-blob "$BLOB"

# S3 path: ViaService set → Put/Get with SSE-KMS ok.
as_user s3api create-bucket --bucket "$BUCKET" >/dev/null
as_user s3api put-object --bucket "$BUCKET" --key probe.txt --body "$BODY" \
	--server-side-encryption aws:kms --ssekms-key-id "$KEY_ID" >/dev/null
as_user s3api get-object --bucket "$BUCKET" --key probe.txt "$OUT" >/dev/null
[[ "$(cat "$OUT")" == "awsbox-via-service" ]]
echo "OK: S3 SSE-KMS Put/Get allowed with kms:ViaService=${VIA}"

# Resource-policy SourceArn / SourceAccount: no account-root crypto delegation —
# only a direct Allow for this user when SourceArn matches the bucket.
write_source_key_policy() {
	local path="$1" bucket_arn="$2"
	python3 - "$path" "$ACCOUNT" "$USER" "$bucket_arn" <<'PY'
import json, sys
path, account, user, bucket_arn = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "RootManage",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam::{account}:root"},
            "Action": [
                "kms:ScheduleKeyDeletion",
                "kms:DescribeKey",
                "kms:PutKeyPolicy",
                "kms:GetKeyPolicy",
                "kms:Encrypt",
            ],
            "Resource": "*",
        },
        {
            "Sid": "S3BucketOnly",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam::{account}:user/{user}"},
            "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
            "Resource": "*",
            "Condition": {
                "StringEquals": {"aws:SourceAccount": account},
                "ArnEquals": {"aws:SourceArn": bucket_arn},
            },
        },
    ],
}, open(path, "w"))
PY
}
write_source_key_policy "$WORKDIR/key-source.json" "$BUCKET_ARN"
aws kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "file://${WORKDIR}/key-source.json" >/dev/null
as_user s3api put-object --bucket "$BUCKET" --key probe2.txt --body "$BODY" \
	--server-side-encryption aws:kms --ssekms-key-id "$KEY_ID" >/dev/null
echo "OK: key policy aws:SourceArn/aws:SourceAccount match allows S3 path"

OTHER_BUCKET_ARN="arn:aws:s3:::awsbox-via-other-${TS}"
write_source_key_policy "$WORKDIR/key-wrong.json" "$OTHER_BUCKET_ARN"
aws kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "file://${WORKDIR}/key-wrong.json" >/dev/null
expect_deny "S3 SSE-KMS denied when key policy SourceArn mismatches" \
	as_user s3api put-object --bucket "$BUCKET" --key probe3.txt --body "$BODY" \
	--server-side-encryption aws:kms --ssekms-key-id "$KEY_ID"

# --- EC2 IamInstanceProfile PassRole limited by PassedToService=ec2 ---
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$PASS_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
PASS_ARN="$(aws iam get-role --role-name "$PASS_ROLE" --query 'Role.Arn' --output text)"
aws iam create-instance-profile --instance-profile-name "$PASS_ROLE" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PASS_ROLE" --role-name "$PASS_ROLE" >/dev/null

python3 - "$WORKDIR/ec2-user-policy.json" "$PASS_ARN" <<'PY'
import json, sys
path, role_arn = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["ec2:RunInstances", "ec2:DescribeInstances", "ec2:TerminateInstances",
                       "events:PutRule", "events:PutTargets", "events:DeleteRule", "events:RemoveTargets"],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": role_arn,
            "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}},
        },
    ],
}, open(path, "w"))
PY
aws iam create-user --user-name "$EC2_USER" >/dev/null
EC2_POLICY_ARN="$(aws iam create-policy --policy-name "$EC2_POLICY" --policy-document "file://${WORKDIR}/ec2-user-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$EC2_USER" --policy-arn "$EC2_POLICY_ARN" >/dev/null
EC2_KEYS="$(aws iam create-access-key --user-name "$EC2_USER" --output json)"
EC2_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$EC2_KEYS")"
EC2_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$EC2_KEYS")"

IID="$(as_ec2_user ec2 run-instances \
	--image-id ami-ubuntu-22.04 \
	--instance-type t3.micro \
	--iam-instance-profile "Name=${PASS_ROLE}" \
	--query 'Instances[0].InstanceId' --output text)"
[[ -n "$IID" && "$IID" != "None" ]]
echo "OK: PassRole allowed for IamInstanceProfile when PassedToService=ec2.amazonaws.com"

RULE="awsbox-via-rule-${TS}"
as_ec2_user events put-rule --name "$RULE" --event-pattern '{"source":["awsbox.via"]}' >/dev/null
expect_deny "PassRole to events denied when PassedToService is ec2 only" \
	as_ec2_user events put-targets --rule "$RULE" \
	--targets "Id=1,Arn=arn:aws:lambda:${REGION}:${ACCOUNT}:function:none,RoleArn=${PASS_ARN}"
as_ec2_user events delete-rule --name "$RULE" >/dev/null 2>&1 || true

echo "OK: service-origin condition keys smoke"
