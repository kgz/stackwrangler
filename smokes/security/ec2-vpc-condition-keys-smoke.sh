#!/usr/bin/env bash
# ec2:Vpc / ec2:ResourceTag / TagSpecifications aws:RequestTag (#664).
# Happy: deploy role CreateSecurityGroup in allowed VPC with RequestTag,
#        then AuthorizeEgress + Delete with Vpc + ResourceTag.
# Sad: same role denied CreateSecurityGroup in another VPC; denied without RequestTag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_SESSION_TOKEN
TS="$(date +%s)"
KEEP="${AWSBOX_EC2_VPC_KEYS_KEEP:-0}"
ACCT="000000000000"
DEPLOY_ROLE="awsbox-ec2vpc-deploy-${TS}"
STACK_NAME="awsbox-ec2vpc-${TS}"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
WORK="${TMPDIR:-/tmp}/awsbox-ec2vpc-$$"
mkdir -p "$WORK"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

VPC_OK=""
VPC_BAD=""
SG_ID=""

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	[[ -n "$SG_ID" ]] && aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1 || true
	if [[ -n "$DEPLOY_ROLE" ]]; then
		aws iam delete-role-policy --role-name "$DEPLOY_ROLE" --policy-name allow >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$DEPLOY_ROLE" >/dev/null 2>&1 || true
	fi
	[[ -n "$VPC_OK" ]] && aws ec2 delete-vpc --vpc-id "$VPC_OK" >/dev/null 2>&1 || true
	[[ -n "$VPC_BAD" ]] && aws ec2 delete-vpc --vpc-id "$VPC_BAD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect_deny() {
	local label="$1" outfile="$2"
	local rc
	rc="$(cat "$outfile.rc")"
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; cat "$outfile" >&2; exit 1; }
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny' "$outfile" \
		|| { echo "FAIL: ${label}: $(cat "$outfile")" >&2; exit 1; }
	echo "OK: ${label}"
}

VPC_OK="$(aws ec2 create-vpc --cidr-block 10.66.0.0/16 --query Vpc.VpcId --output text)"
VPC_BAD="$(aws ec2 create-vpc --cidr-block 10.67.0.0/16 --query Vpc.VpcId --output text)"
VPC_OK_ARN="arn:aws:ec2:${REGION}:${ACCT}:vpc/${VPC_OK}"

cat >"$WORK/deploy-trust.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::000000000000:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
aws iam create-role \
	--role-name "$DEPLOY_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" >/dev/null

# Mirrors CFN deploy-role SG scoping (stack-name tag stands in for
# aws:cloudformation:stack-name — same condition-key wiring).
cat >"$WORK/deploy-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
      "Resource": "*",
      "Condition": {
        "ArnEquals": {
          "ec2:Vpc": "${VPC_OK_ARN}"
        },
        "StringEquals": {
          "aws:RequestTag/stack-name": "${STACK_NAME}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:DeleteSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags"
      ],
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "ArnEquals": {
          "ec2:Vpc": "${VPC_OK_ARN}"
        },
        "StringEquals": {
          "ec2:ResourceTag/stack-name": "${STACK_NAME}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCT}:role/${DEPLOY_ROLE}"
    }
  ]
}
EOF
aws iam put-role-policy \
	--role-name "$DEPLOY_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/deploy-inline.json" >/dev/null

CREDS="$(aws sts assume-role \
	--role-arn "arn:aws:iam::${ACCT}:role/${DEPLOY_ROLE}" \
	--role-session-name ec2vpc-smoke \
	--query 'Credentials' --output json)"
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])' <<<"$CREDS")"

# Deny: wrong VPC (even with matching RequestTag).
set +e
aws ec2 create-security-group \
	--group-name "awsbox-ec2vpc-bad-${TS}" \
	--description "wrong vpc" \
	--vpc-id "$VPC_BAD" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	>"$WORK/create-bad.out" 2>&1
echo $? >"$WORK/create-bad.out.rc"
set -e
expect_deny "create-security-group in other VPC denied" "$WORK/create-bad.out"

# Deny: allowed VPC but missing RequestTag.
set +e
aws ec2 create-security-group \
	--group-name "awsbox-ec2vpc-notag-${TS}" \
	--description "no request tag" \
	--vpc-id "$VPC_OK" \
	>"$WORK/create-notag.out" 2>&1
echo $? >"$WORK/create-notag.out.rc"
set -e
expect_deny "create-security-group without RequestTag denied" "$WORK/create-notag.out"

# Allow: matching VPC + TagSpecifications RequestTag.
SG_ID="$(aws ec2 create-security-group \
	--group-name "awsbox-ec2vpc-ok-${TS}" \
	--description "allowed vpc" \
	--vpc-id "$VPC_OK" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	--query GroupId --output text)"
echo "OK: create-security-group in allowed VPC with RequestTag"

# Allow: authorize egress on tagged SG in VPC.
aws ec2 authorize-security-group-egress \
	--group-id "$SG_ID" \
	--ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
	>/dev/null
echo "OK: authorize-security-group-egress with ec2:Vpc + ResourceTag"

# Allow: delete tagged SG.
aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null
SG_ID=""
echo "OK: delete-security-group with ec2:Vpc + ResourceTag"

unset AWS_SESSION_TOKEN
export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"

echo "OK: ec2:Vpc / ResourceTag / TagSpecifications condition key smoke"
