#!/usr/bin/env bash
# Dual-target: EC2 SG ec2:Vpc / ResourceTag / RequestTag / CreateAction (#664/#669).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
ACCT="$PARITY_ACCOUNT"
REGION="$PARITY_REGION"
DEPLOY_ROLE="sw-parity-ec2vpc-deploy-${TS}"
CA_ROLE="sw-parity-ec2vpc-ca-${TS}"
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
SG_CA=""

# Cleanup runs reverse registration order: restore admin first, then SGs, then VPCs/roles.
on_cleanup '[[ -n "$VPC_OK" ]] && aws ec2 delete-vpc --vpc-id "$VPC_OK"'
on_cleanup '[[ -n "$VPC_BAD" ]] && aws ec2 delete-vpc --vpc-id "$VPC_BAD"'
on_cleanup "aws iam delete-role-policy --role-name '$DEPLOY_ROLE' --policy-name allow; aws iam delete-role --role-name '$DEPLOY_ROLE'"
on_cleanup "aws iam delete-role-policy --role-name '$CA_ROLE' --policy-name allow; aws iam delete-role --role-name '$CA_ROLE'"
on_cleanup '[[ -n "$SG_ID" ]] && aws ec2 delete-security-group --group-id "$SG_ID"'
on_cleanup '[[ -n "$SG_BARE" ]] && aws ec2 delete-security-group --group-id "$SG_BARE"'
on_cleanup '[[ -n "$SG_CA" ]] && aws ec2 delete-security-group --group-id "$SG_CA"'
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
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation' "$outfile" \
		|| {
			echo "FAIL: ${label}: $(cat "$outfile")" >&2
			exit 1
		}
	parity_pass "$label"
}

assume_role() {
	local role_name="$1" session="$2"
	local creds
	creds="$(aws sts assume-role \
		--role-arn "arn:aws:iam::${ACCT}:role/${role_name}" \
		--role-session-name "$session" \
		--query 'Credentials' --output json)"
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])' <<<"$creds")"
	AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])' <<<"$creds")"
	AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])' <<<"$creds")"
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
aws iam create-role \
	--role-name "$CA_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" >/dev/null

# Real AWS: CreateSecurityGroup must name the VPC ARN (Resource "*" authorizes any VPC).
# aws:RequestTag is not in the CreateSecurityGroup context for security-group/* — tag-on-create
# is enforced via CreateTags + ec2:CreateAction.
# LocalEmu: CreateSecurityGroup still uses Resource "*" + ec2:Vpc (multi-resource ARN gap);
# CreateTags + ec2:CreateAction matches AWS (#669).
if [[ "$PARITY_TARGET" == "real" ]]; then
	CREATE_SG_RESOURCE=$(cat <<EOF
      "Resource": [
        "${VPC_OK_ARN}",
        "arn:aws:ec2:${REGION}:${ACCT}:security-group/*"
      ]
EOF
	)
else
	CREATE_SG_RESOURCE=$(cat <<EOF
      "Resource": "*",
      "Condition": {
        "ArnEquals": { "ec2:Vpc": "${VPC_OK_ARN}" }
      }
EOF
	)
fi

cat >"$WORK/deploy-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
${CREATE_SG_RESOURCE}
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

# CreateAction-only CreateTags: tag-on-create allowed; standalone CreateTags denied (#669).
cat >"$WORK/ca-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
${CREATE_SG_RESOURCE}
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
      "Action": "ec2:DeleteSecurityGroup",
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*"
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCT}:role/${CA_ROLE}"
    }
  ]
}
EOF

aws iam put-role-policy \
	--role-name "$DEPLOY_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/deploy-inline.json" >/dev/null
aws iam put-role-policy \
	--role-name "$CA_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/ca-inline.json" >/dev/null

parity_wait_iam 10

# --- CreateAction-only role: happy tag-on-create + sad standalone CreateTags (#669) ---
assume_role "$CA_ROLE" ec2vpc-ca

SG_CA="$(aws ec2 create-security-group \
	--group-name "sw-parity-ec2vpc-ca-${TS}" \
	--description "create-action only" \
	--vpc-id "$VPC_OK" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	--query GroupId --output text)"
parity_pass "create-security-group with CreateAction-gated CreateTags"

# Matching RequestTag so the only failing condition is absent ec2:CreateAction.
set +e
aws ec2 create-tags \
	--resources "$SG_CA" \
	--tags "Key=stack-name,Value=${STACK_NAME}" \
	>"$WORK/ca-standalone.out" 2>&1
echo $? >"$WORK/ca-standalone.out.rc"
set -e
expect_deny "standalone create-tags denied without CreateAction" "$WORK/ca-standalone.out"

aws ec2 delete-security-group --group-id "$SG_CA" >/dev/null
SG_CA=""

# Wrong CreateAction: Allow CreateTags only when CreateAction=CreateVpc, then tag-on-create
# via CreateSecurityGroup (sets CreateAction=CreateSecurityGroup) → deny. RequestTag matches.
parity_restore_admin "$ADMIN_KEY" "$ADMIN_SECRET" "$ADMIN_TOKEN"
cat >"$WORK/ca-wrong-action.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2:CreateSecurityGroup",
${CREATE_SG_RESOURCE}
    },
    {
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:${REGION}:${ACCT}:security-group/*",
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": "CreateVpc",
          "aws:RequestTag/stack-name": "${STACK_NAME}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCT}:role/${CA_ROLE}"
    }
  ]
}
EOF
aws iam put-role-policy \
	--role-name "$CA_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/ca-wrong-action.json" >/dev/null
parity_wait_iam 5
assume_role "$CA_ROLE" ec2vpc-ca-wrong

set +e
aws ec2 create-security-group \
	--group-name "sw-parity-ec2vpc-ca-wrongact-${TS}" \
	--description "wrong CreateAction policy" \
	--vpc-id "$VPC_OK" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=stack-name,Value=${STACK_NAME}}]" \
	>"$WORK/ca-wrongact.out" 2>&1
echo $? >"$WORK/ca-wrongact.out.rc"
set -e
expect_deny "create-security-group denied when CreateAction is CreateVpc (wrong parent)" "$WORK/ca-wrongact.out"

parity_restore_admin "$ADMIN_KEY" "$ADMIN_SECRET" "$ADMIN_TOKEN"

# --- Full deploy role: Vpc / ResourceTag / CreateAction (#664 + #669) ---
assume_role "$DEPLOY_ROLE" ec2vpc-parity

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

# Tag-on-create gated by CreateTags + ec2:CreateAction + aws:RequestTag.
# Untagged create is allowed (CreateTags not evaluated).
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
