#!/usr/bin/env bash
# CFN resource ops run as the caller (or RoleARN) through IAM (#524).
#
# Sad create: role with only cloudformation:* → CREATE_FAILED / IAM message in events.
# Happy create: same role plus iam/sqs/logs create perms → CREATE_COMPLETE.
# Sad delete: role without iam:DeleteRole → DELETE_FAILED.
# Admin create still succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cloudformation/caller-iam"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
ACCOUNT="$(aws --endpoint-url "$EP" --region "$REGION" \
	sts get-caller-identity --query Account --output text 2>/dev/null || echo 000000000000)"

CFN_ONLY_ROLE="awsbox-cfn-caller-only-${TS}"
FULL_ROLE="awsbox-cfn-caller-full-${TS}"
NODELETE_ROLE="awsbox-cfn-caller-nodelete-${TS}"
STACK_DENY="awsbox-cfn-caller-deny-${TS}"
STACK_OK="awsbox-cfn-caller-ok-${TS}"
STACK_ADMIN="awsbox-cfn-caller-admin-${TS}"
STACK_DEL="awsbox-cfn-caller-del-${TS}"
PROBE_ROLE="awsbox-cfn-probe-role-${TS}"
PROBE_QUEUE="awsbox-cfn-probe-q-${TS}"
PROBE_LG="/awsbox/cfn-caller-${TS}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cfn-caller-iam.XXXXXX")"
cleanup() {
	export AWS_ACCESS_KEY_ID="$KEY"
	export AWS_SECRET_ACCESS_KEY="$SECRET"
	unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_DENY" >/dev/null 2>&1 || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_OK" >/dev/null 2>&1 || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_ADMIN" >/dev/null 2>&1 || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_DEL" >/dev/null 2>&1 || true
	for r in "$CFN_ONLY_ROLE" "$FULL_ROLE" "$NODELETE_ROLE" "awsbox-cfn-svc-${TS}" "awsbox-cfn-passer-${TS}"; do
		aws_admin iam delete-role-policy --role-name "$r" --policy-name inline >/dev/null 2>&1 || true
		aws_admin iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	aws_admin cloudformation delete-stack --stack-name "awsbox-cfn-caller-rolearn-${TS}" >/dev/null 2>&1 || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

aws_admin() {
	AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SECRET" \
		command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

assume_env() {
	local role_arn="$1" session="$2"
	local creds
	creds="$(aws_admin sts assume-role --role-arn "$role_arn" --role-session-name "$session" --output json)"
	export AWS_ACCESS_KEY_ID
	export AWS_SECRET_ACCESS_KEY
	export AWS_SESSION_TOKEN
	AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')"
	AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')"
	AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])')"
}

aws_as() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

wait_stack_terminal() {
	local stack="$1" timeout="${2:-90}"
	local i st
	for i in $(seq 1 "$timeout"); do
		st="$(aws_admin cloudformation describe-stacks --stack-name "$stack" \
			--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)"
		case "$st" in
			*COMPLETE|*FAILED|*ROLLBACK*)
				echo "$st"
				return 0
				;;
		esac
		sleep 2
	done
	echo "TIMEOUT"
	return 1
}

events_blob() {
	local stack="$1"
	aws_admin cloudformation describe-stack-events --stack-name "$stack" \
		--query 'StackEvents[].{L:LogicalResourceId,S:ResourceStatus,R:ResourceStatusReason}' \
		--output text 2>/dev/null || true
}

cat >"$WORKDIR/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${ACCOUNT}:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat >"$WORKDIR/cfn-only.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "cloudformation:*",
    "Resource": "*"
  }]
}
EOF

cat >"$WORKDIR/full.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "cloudformation:*",
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
      "sqs:CreateQueue",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:DeleteQueue",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:SetQueueAttributes",
      "logs:CreateLogGroup",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:ListTagsLogGroup"
    ],
    "Resource": "*"
  }]
}
EOF

# Full create/delete surface minus iam:DeleteRole (CFN also lists role policies first).
cat >"$WORKDIR/nodelete.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "cloudformation:*",
      "iam:CreateRole",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
      "sqs:CreateQueue",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:DeleteQueue",
      "sqs:TagQueue",
      "sqs:UntagQueue",
      "sqs:SetQueueAttributes",
      "logs:CreateLogGroup",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:ListTagsLogGroup"
    ],
    "Resource": "*"
  }]
}
EOF

echo "==> create deploy roles"
aws_admin iam create-role --role-name "$CFN_ONLY_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$CFN_ONLY_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/cfn-only.json" >/dev/null

aws_admin iam create-role --role-name "$FULL_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$FULL_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/full.json" >/dev/null

aws_admin iam create-role --role-name "$NODELETE_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$NODELETE_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/nodelete.json" >/dev/null

PARAMS=(
	"ParameterKey=RoleName,ParameterValue=${PROBE_ROLE}-a"
	"ParameterKey=QueueName,ParameterValue=${PROBE_QUEUE}-a"
	"ParameterKey=LogGroupName,ParameterValue=${PROBE_LG}-a"
)

echo "==> sad: create-stack as cloudformation-only role"
assume_env "arn:aws:iam::${ACCOUNT}:role/${CFN_ONLY_ROLE}" cfn-deny
aws_as cloudformation create-stack \
	--stack-name "$STACK_DENY" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters "${PARAMS[@]}" >/dev/null

ST="$(wait_stack_terminal "$STACK_DENY" 60)"
echo "    status=${ST}"
case "$ST" in
	CREATE_FAILED|*ROLLBACK*) ;;
	*)
		echo "FAIL: expected CREATE_FAILED/ROLLBACK, got ${ST}" >&2
		events_blob "$STACK_DENY" >&2
		exit 1
		;;
esac
BLOB="$(events_blob "$STACK_DENY")"
echo "$BLOB" | grep -qiE 'not authorized|AccessDenied|iam:CreateRole|sqs:CreateQueue|logs:CreateLogGroup' || {
	echo "FAIL: expected IAM deny in stack events:" >&2
	echo "$BLOB" >&2
	exit 1
}
echo "OK: limited role → resource IAM deny in stack events"

echo "==> happy: create-stack as full deploy role"
assume_env "arn:aws:iam::${ACCOUNT}:role/${FULL_ROLE}" cfn-full
aws_as cloudformation create-stack \
	--stack-name "$STACK_OK" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters \
	"ParameterKey=RoleName,ParameterValue=${PROBE_ROLE}-b" \
	"ParameterKey=QueueName,ParameterValue=${PROBE_QUEUE}-b" \
	"ParameterKey=LogGroupName,ParameterValue=${PROBE_LG}-b" >/dev/null

ST="$(wait_stack_terminal "$STACK_OK" 90)"
echo "    status=${ST}"
[[ "$ST" == "CREATE_COMPLETE" ]] || {
	echo "FAIL: expected CREATE_COMPLETE, got ${ST}" >&2
	events_blob "$STACK_OK" >&2
	exit 1
}
echo "OK: full deploy role → CREATE_COMPLETE"

echo "==> admin create still works"
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
aws_admin cloudformation create-stack \
	--stack-name "$STACK_ADMIN" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters \
	"ParameterKey=RoleName,ParameterValue=${PROBE_ROLE}-c" \
	"ParameterKey=QueueName,ParameterValue=${PROBE_QUEUE}-c" \
	"ParameterKey=LogGroupName,ParameterValue=${PROBE_LG}-c" >/dev/null
ST="$(wait_stack_terminal "$STACK_ADMIN" 90)"
[[ "$ST" == "CREATE_COMPLETE" ]] || {
	echo "FAIL: admin create expected CREATE_COMPLETE, got ${ST}" >&2
	exit 1
}
echo "OK: admin keys → CREATE_COMPLETE"

echo "==> sad delete: stack created as full role, delete without iam:DeleteRole"
assume_env "arn:aws:iam::${ACCOUNT}:role/${FULL_ROLE}" cfn-del-create
aws_as cloudformation create-stack \
	--stack-name "$STACK_DEL" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters \
	"ParameterKey=RoleName,ParameterValue=${PROBE_ROLE}-d" \
	"ParameterKey=QueueName,ParameterValue=${PROBE_QUEUE}-d" \
	"ParameterKey=LogGroupName,ParameterValue=${PROBE_LG}-d" >/dev/null
ST="$(wait_stack_terminal "$STACK_DEL" 90)"
[[ "$ST" == "CREATE_COMPLETE" ]] || {
	echo "FAIL: setup create for delete test got ${ST}" >&2
	events_blob "$STACK_DEL" >&2
	exit 1
}

assume_env "arn:aws:iam::${ACCOUNT}:role/${NODELETE_ROLE}" cfn-del
aws_as cloudformation delete-stack --stack-name "$STACK_DEL" >/dev/null
ST="$(wait_stack_terminal "$STACK_DEL" 90)"
echo "    delete status=${ST}"
[[ "$ST" == "DELETE_FAILED" ]] || {
	echo "FAIL: expected DELETE_FAILED, got ${ST}" >&2
	events_blob "$STACK_DEL" >&2
	exit 1
}
BLOB="$(events_blob "$STACK_DEL")"
echo "$BLOB" | grep -qiE 'not authorized|AccessDenied|iam:DeleteRole' || {
	echo "FAIL: expected iam:DeleteRole deny in delete events:" >&2
	echo "$BLOB" >&2
	exit 1
}
echo "OK: delete without iam:DeleteRole → DELETE_FAILED"

echo "==> RoleARN: create-stack uses service role (caller needs iam:PassRole)"
SVC_ROLE="awsbox-cfn-svc-${TS}"
STACK_ROLEARN="awsbox-cfn-caller-rolearn-${TS}"
cat >"$WORKDIR/cfn-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "cloudformation.amazonaws.com"},
    "Action": "sts:AssumeRole"
  },{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${ACCOUNT}:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
aws_admin iam create-role --role-name "$SVC_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/cfn-trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$SVC_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/full.json" >/dev/null
# Caller can CFN + PassRole only — resource creates must use RoleARN session.
cat >"$WORKDIR/pass.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":"cloudformation:*","Resource":"*"},
    {"Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::${ACCOUNT}:role/${SVC_ROLE}"}
  ]
}
EOF
PASS_ROLE="awsbox-cfn-passer-${TS}"
aws_admin iam create-role --role-name "$PASS_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$PASS_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/pass.json" >/dev/null

assume_env "arn:aws:iam::${ACCOUNT}:role/${PASS_ROLE}" cfn-pass
aws_as cloudformation create-stack \
	--stack-name "$STACK_ROLEARN" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--role-arn "arn:aws:iam::${ACCOUNT}:role/${SVC_ROLE}" \
	--parameters \
	"ParameterKey=RoleName,ParameterValue=${PROBE_ROLE}-e" \
	"ParameterKey=QueueName,ParameterValue=${PROBE_QUEUE}-e" \
	"ParameterKey=LogGroupName,ParameterValue=${PROBE_LG}-e" >/dev/null
ST="$(wait_stack_terminal "$STACK_ROLEARN" 90)"
echo "    RoleARN status=${ST}"
[[ "$ST" == "CREATE_COMPLETE" ]] || {
	echo "FAIL: RoleARN create expected CREATE_COMPLETE, got ${ST}" >&2
	events_blob "$STACK_ROLEARN" >&2
	exit 1
}
echo "OK: RoleARN service role → CREATE_COMPLETE"

# cleanup extras for RoleARN
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
aws_admin cloudformation delete-stack --stack-name "$STACK_ROLEARN" >/dev/null 2>&1 || true
aws_admin iam delete-role-policy --role-name "$SVC_ROLE" --policy-name inline >/dev/null 2>&1 || true
aws_admin iam delete-role --role-name "$SVC_ROLE" >/dev/null 2>&1 || true
aws_admin iam delete-role-policy --role-name "$PASS_ROLE" --policy-name inline >/dev/null 2>&1 || true
aws_admin iam delete-role --role-name "$PASS_ROLE" >/dev/null 2>&1 || true

echo "OK: cfn-caller-iam-smoke (${TS})"
