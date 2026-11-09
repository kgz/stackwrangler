#!/usr/bin/env bash
# Dual-target: EC2 SG ec2:Vpc / ResourceTag / RequestTag (#664).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
ACCT="$PARITY_ACCOUNT"
REGION="$PARITY_REGION"
DEPLOY_ROLE="sw-parity-ec2vpc-deploy-${TS}"
STACK_NAME="sw-parity-ec2vpc-${TS}"
ADMIN_KEY="${AWS_ACCESS_KEY_ID-}"
ADMIN_SECRET="${AWS_SECRET_ACCESS_KEY-}"
ADMIN_TOKEN="${AWS_SESSION_TOKEN-}"
WORK="${TMPDIR:-/tmp}/sw-parity-ec2vpc-$$"
mkdir -p "$WORK"
on_cleanup "rm -rf '$WORK'"

VPC_OK=""
VPC_BAD=""
SG_ID=""
SG_BARE=""

# Cleanup runs reverse registration order: restore admin first, then SGs, then VPCs/role.
on_cleanup '[[ -n "$VPC_OK" ]] && aws ec2 delete-vpc --vpc-id "$VPC_OK"'
on_cleanup '[[ -n "$VPC_BAD" ]] && aws ec2 delete-vpc --vpc-id "$VPC_BAD"'
on_cleanup "aws iam delete-role-policy --role-name '$DEPLOY_ROLE' --policy-name allow; aws iam delete-role --role-name '$DEPLOY_ROLE'"
on_cleanup '[[ -n "$SG_ID" ]] && aws ec2 delete-security-group --group-id "$SG_ID"'
on_cleanup '[[ -n "$SG_BARE" ]] && aws ec2 delete-security-group --group-id "$SG_BARE"'
on_cleanup 'parity_restore_admin "$ADMIN_KEY" "$ADMIN_SECRET" "$ADMIN_TOKEN"'

expect_deny() {
	local label="$1" outfile="$2"
	local rc
	rc="$(cat "$outfile.rc")"
	[[ "$rc" -ne 0 ]] || {
		echo "FAIL: ${label} succeeded" >&2
		cat "$outfile" >&2
		exit 1
	}
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny' "$outfile" \
		|| {
			echo "FAIL: ${label}: $(cat "$outfile")" >&2
			exit 1
		}
	parity_pass "$label"
}

VPC_OK="$(aws ec2 create-vpc --cidr-block 10.66.0.0/16 --query Vpc.VpcId --output text)"
VPC_BAD="$(aws ec2 create-vpc --cidr-block 10.67.0.0/16 --query Vpc.VpcId --output text)"
VPC_OK_ARN="arn:aws:ec2:${REGION}:${ACCT}:vpc/${VPC_OK}"

SG_BARE="$(aws ec2 create-security-group \
	--group-name "sw-parity-ec2vpc-bare-${TS}" \
	--description "no stack tag" \
	--vpc-id "$VPC_OK" \
	--query GroupId --output text)"

cat >"$WORK/deploy-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${ACCT}:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
aws iam create-role \
	--role-name "$DEPLOY_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" >/dev/null

# Real AWS: CreateSecurityGroup must name the VPC ARN (Resource "*" authorizes any VPC).
# aws:RequestTag is not in the CreateSecurityGroup context for security-group/* — tag-on-create
# is enforced via CreateTags + ec2:CreateAction. LocalEmu still evaluates RequestTag on create.
if [[ "$PARITY_TARGET" == "real" ]]; then
	cat >"$WORK/deploy-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
      "Resource": [
        "${VPC_OK_ARN}",
        "arn:aws:ec2:${REGION}:${ACCT}:security-group/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": "CreateSecurityGroup",
          "aws:RequestTag/stack-name": "${STACK_NAME}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:DeleteSecurityGroup"
      ],
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" },
        "StringEquals": { "ec2:ResourceTag/stack-name": "${STACK_NAME}" }
      }
    },
    {
      "Effect": "Allow",
      "Action": [ "ec2:CreateTags", "ec2:DeleteTags" ],
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" },
        "StringEquals": {
          "ec2:ResourceTag/stack-name": "${STACK_NAME}",
          "aws:ResourceTag/stack-name": "${STACK_NAME}"
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
else
	cat >"$WORK/deploy-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
      "Resource": "*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" },
        "StringEquals": { "aws:RequestTag/stack-name": "${STACK_NAME}" }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:DeleteSecurityGroup"
      ],
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" },
        "StringEquals": { "ec2:ResourceTag/stack-name": "${STACK_NAME}" }
      }
    },
    {
      "Effect": "Allow",
      "Action": [ "ec2:CreateTags", "ec2:DeleteTags" ],
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" },
        "StringEquals": {
          "ec2:ResourceTag/stack-name": "${STACK_NAME}",
          "aws:ResourceTag/stack-name": "${STACK_NAME}"
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
fi
aws iam put-role-policy \
	--role-name "$DEPLOY_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/deploy-inline.json" >/dev/null

parity_wait_iam 10
CREDS="$(aws sts assume-role \
	--role-arn "arn:aws:iam::${ACCT}:role/${DEPLOY_ROLE}" \
	--role-session-name ec2vpc-parity \
	--query 'Credentials' --output json)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])' <<<"$CREDS")"

set +e
aws ec2 create-security-group \
	--group-name "sw-parity-ec2vpc-bad-${TS}" \
	--description "wrong vpc" \
	--vpc-id "$VPC_BAD" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	>"$WORK/create-bad.out" 2>&1
echo $? >"$WORK/create-bad.out.rc"
set -e
expect_deny "create-security-group in other VPC denied" "$WORK/create-bad.out"

# Real AWS: CreateSecurityGroup auth context for security-group/* does not include
# aws:RequestTag / ec2:Vpc (decoded UnauthorizedOperation). Tag-on-create is gated by
# CreateTags + ec2:CreateAction + aws:RequestTag. Untagged create is allowed.
# LocalEmu: RequestTag can be enforced on CreateSecurityGroup itself (#664 smoke).
if [[ "$PARITY_TARGET" == "real" ]]; then
	set +e
	aws ec2 create-security-group \
		--group-name "sw-parity-ec2vpc-badtag-${TS}" \
		--description "mismatched request tag" \
		--vpc-id "$VPC_OK" \
		--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=wrong-${STACK_NAME}}]" \
		>"$WORK/create-badtag.out" 2>&1
	echo $? >"$WORK/create-badtag.out.rc"
	set -e
	expect_deny "create-security-group with mismatched RequestTag denied (CreateTags)" "$WORK/create-badtag.out"
else
	set +e
	aws ec2 create-security-group \
		--group-name "sw-parity-ec2vpc-notag-${TS}" \
		--description "no request tag" \
		--vpc-id "$VPC_OK" \
		>"$WORK/create-notag.out" 2>&1
	echo $? >"$WORK/create-notag.out.rc"
	set -e
	expect_deny "create-security-group without RequestTag denied" "$WORK/create-notag.out"
fi

SG_ID="$(aws ec2 create-security-group \
	--group-name "sw-parity-ec2vpc-ok-${TS}" \
	--description "allowed vpc" \
	--vpc-id "$VPC_OK" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	--query GroupId --output text)"
parity_pass "create-security-group in allowed VPC with RequestTag"

set +e
aws ec2 create-tags \
	--resources "$SG_BARE" \
	--tags "Key=env,Value=prod" \
	>"$WORK/tags-bare.out" 2>&1
echo $? >"$WORK/tags-bare.out.rc"
set -e
expect_deny "create-tags on untagged SG denied" "$WORK/tags-bare.out"

aws ec2 create-tags \
	--resources "$SG_ID" \
	--tags "Key=env,Value=prod" >/dev/null
parity_pass "create-tags with ec2:Vpc + ec2:ResourceTag + aws:ResourceTag"

aws ec2 delete-tags \
	--resources "$SG_ID" \
	--tags "Key=env,Value=prod" >/dev/null
parity_pass "delete-tags with ec2:Vpc + ec2:ResourceTag + aws:ResourceTag"

aws ec2 authorize-security-group-egress \
	--group-id "$SG_ID" \
	--ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
	>/dev/null
parity_pass "authorize-security-group-egress with ec2:Vpc + ResourceTag"

aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null
SG_ID=""
parity_pass "delete-security-group with ec2:Vpc + ResourceTag"

parity_restore_admin "$ADMIN_KEY" "$ADMIN_SECRET" "$ADMIN_TOKEN"

parity_pass "ec2-vpc-condition-keys"
parity_finish
