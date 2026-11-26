#!/usr/bin/env bash
# #825: user-supplied aws:-prefixed EC2 tag keys are rejected (InvalidParameterValue).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

TS="$(date +%s)"
VPC=""
SG=""

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

cleanup() {
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

expect_invalid() {
	local label="$1" outfile="$2"
	local rc
	rc="$(cat "$outfile.rc")"
	[[ "$rc" -ne 0 ]] || fail "${label} succeeded"
	grep -qiE 'InvalidParameterValue|reserved for internal use|aws:' "$outfile" \
		|| fail "${label}: expected InvalidParameterValue, got $(cat "$outfile")"
	echo "OK: $label"
}

WORK="${TMPDIR:-/tmp}/sw-ec2-reserved-tags-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"; cleanup' EXIT

VPC="$(aws ec2 create-vpc --cidr-block 10.82.0.0/16 --query Vpc.VpcId --output text)"
SG="$(aws ec2 create-security-group \
	--group-name "sw-reserved-tags-${TS}" \
	--description "reserved tag smoke" \
	--vpc-id "$VPC" \
	--query GroupId --output text)"

# Standalone CreateTags with aws: key must fail before IAM.
set +e
aws ec2 create-tags --resources "$SG" \
	--tags Key=aws:cloudformation:stack-name,Value=forged \
	>"$WORK/create.out" 2>&1
echo $? >"$WORK/create.out.rc"
set -e
expect_invalid "create-tags rejects aws:cloudformation:stack-name" "$WORK/create.out"

# Tag-on-create TagSpecifications with aws: key must fail.
set +e
aws ec2 create-security-group \
	--group-name "sw-reserved-tags-spec-${TS}" \
	--description "reserved tag-on-create" \
	--vpc-id "$VPC" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=aws:cloudformation:logical-id,Value=Sg}]" \
	>"$WORK/spec.out" 2>&1
echo $? >"$WORK/spec.out.rc"
set -e
expect_invalid "create-security-group TagSpecifications reject aws:" "$WORK/spec.out"

# Normal tag still works.
aws ec2 create-tags --resources "$SG" --tags Key=stack-name,Value=ok >/dev/null
got="$(aws ec2 describe-tags --filters "Name=resource-id,Values=$SG" "Name=key,Values=stack-name" \
	--query 'Tags[0].Value' --output text)"
[[ "$got" == "ok" ]] || fail "normal create-tags failed (got ${got})"
echo "OK: normal create-tags still works"

# DeleteTags of an aws: key (if somehow present) is also rejected — seed via moto is
# unnecessary; attempt delete of a reserved key name still fails the parameter check.
set +e
aws ec2 delete-tags --resources "$SG" --tags Key=aws:cloudformation:stack-name \
	>"$WORK/del.out" 2>&1
echo $? >"$WORK/del.out.rc"
set -e
expect_invalid "delete-tags rejects aws: key" "$WORK/del.out"

echo "OK: ec2 reserved aws: tag keys (#825)"
