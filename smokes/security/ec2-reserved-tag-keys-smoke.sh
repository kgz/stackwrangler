#!/usr/bin/env bash
# #825: user-supplied aws:-prefixed EC2 tag keys are rejected (InvalidParameterValue)
# before IAM; CloudFormation can still set aws:cloudformation:* system tags.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
ADMIN_KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
ADMIN_SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

TS="$(date +%s)"
ACCT=""
VPC=""
SG=""
DENY_ROLE="sw-reserved-deny-${TS}"
STACK="sw-reserved-cfn-${TS}"
WORK="${TMPDIR:-/tmp}/sw-ec2-reserved-tags-$$"
mkdir -p "$WORK"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

cleanup() {
	aws cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1 || true
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$DENY_ROLE" --policy-name deny-tags >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$DENY_ROLE" >/dev/null 2>&1 || true
	rm -rf "$WORK"
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	unset AWS_SESSION_TOKEN || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

expect_invalid() {
	local label="$1" outfile="$2"
	local rc
	rc="$(cat "$outfile.rc")"
	[[ "$rc" -ne 0 ]] || fail "${label} succeeded"
	grep -qiE 'InvalidParameterValue' "$outfile" \
		|| fail "${label}: expected InvalidParameterValue, got $(cat "$outfile")"
	grep -qiE 'AccessDenied|not authorized|UnauthorizedOperation' "$outfile" \
		&& fail "${label}: got AccessDenied instead of InvalidParameterValue — $(cat "$outfile")"
	echo "OK: $label"
}

ACCT="$(aws sts get-caller-identity --query Account --output text)"
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

# RunInstances TagSpecifications with aws: must also fail (non-Create* path).
set +e
aws ec2 run-instances --image-id ami-00000000 --instance-type t2.micro --count 1 \
	--tag-specifications "ResourceType=instance,Tags=[{Key=aws:ec2:legacy,Value=x}]" \
	>"$WORK/run.out" 2>&1
echo $? >"$WORK/run.out.rc"
set -e
expect_invalid "run-instances TagSpecifications reject aws:" "$WORK/run.out"

# Normal tag still works.
aws ec2 create-tags --resources "$SG" --tags Key=stack-name,Value=ok >/dev/null
got="$(aws ec2 describe-tags --filters "Name=resource-id,Values=$SG" "Name=key,Values=stack-name" \
	--query 'Tags[0].Value' --output text)"
[[ "$got" == "ok" ]] || fail "normal create-tags failed (got ${got})"
echo "OK: normal create-tags still works"

# DeleteTags of an aws: key is also rejected.
set +e
aws ec2 delete-tags --resources "$SG" --tags Key=aws:cloudformation:stack-name \
	>"$WORK/del.out" 2>&1
echo $? >"$WORK/del.out.rc"
set -e
expect_invalid "delete-tags rejects aws: key" "$WORK/del.out"

# Constrained principal: CreateTags would AccessDenied — reserved key must still
# surface InvalidParameterValue (proves pre-IAM ordering).
cat >"$WORK/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${ACCT}:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
cat >"$WORK/deny.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Deny",
    "Action": ["ec2:CreateTags", "ec2:DeleteTags"],
    "Resource": "*"
  }]
}
EOF
aws iam create-role --role-name "$DENY_ROLE" \
	--assume-role-policy-document "file://$WORK/trust.json" >/dev/null
aws iam put-role-policy --role-name "$DENY_ROLE" --policy-name deny-tags \
	--policy-document "file://$WORK/deny.json" >/dev/null

creds="$(aws sts assume-role \
	--role-arn "arn:aws:iam::${ACCT}:role/${DENY_ROLE}" \
	--role-session-name reserved-deny \
	--query Credentials --output json)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])' <<<"$creds")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])' <<<"$creds")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])' <<<"$creds")"

set +e
aws ec2 create-tags --resources "$SG" \
	--tags Key=aws:cloudformation:stack-name,Value=forged-by-deny-role \
	>"$WORK/deny.out" 2>&1
echo $? >"$WORK/deny.out.rc"
set -e
expect_invalid "deny-role create-tags still InvalidParameterValue (pre-IAM)" "$WORK/deny.out"

export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
unset AWS_SESSION_TOKEN || true

# CFN provider must still set aws:cloudformation:* on create.
cat >"$WORK/sg.yaml" <<EOF
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  SmokeSg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: reserved-tag cfn allow
      VpcId: ${VPC}
      Tags:
        - Key: Name
          Value: sw-reserved-cfn-${TS}
EOF
aws cloudformation deploy --stack-name "$STACK" --template-file "$WORK/sg.yaml" \
	--no-fail-on-empty-changeset >/dev/null
CFN_SG="$(aws cloudformation describe-stack-resources --stack-name "$STACK" \
	--logical-resource-id SmokeSg --query 'StackResources[0].PhysicalResourceId' --output text)"
[[ "$CFN_SG" == sg-* ]] || fail "CFN did not create SG (got ${CFN_SG})"
stack_tag="$(aws ec2 describe-tags --filters "Name=resource-id,Values=$CFN_SG" \
	"Name=key,Values=aws:cloudformation:stack-name" --query 'Tags[0].Value' --output text)"
[[ "$stack_tag" == "$STACK" ]] || fail "CFN aws:cloudformation:stack-name missing (got ${stack_tag})"
logical="$(aws ec2 describe-tags --filters "Name=resource-id,Values=$CFN_SG" \
	"Name=key,Values=aws:cloudformation:logical-id" --query 'Tags[0].Value' --output text)"
[[ "$logical" == "SmokeSg" ]] || fail "CFN aws:cloudformation:logical-id missing (got ${logical})"
echo "OK: CFN still sets aws:cloudformation:* system tags"

echo "OK: ec2 reserved aws: tag keys (#825)"
