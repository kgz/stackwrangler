#!/usr/bin/env bash
# CFN AWS::IAM::Role as a path-scoped deploy role (#679).
#
# Sad: CreateRole/PutRolePolicy only on role/<path>/* → iam:GetRole AccessDenied
#      on pathless role/<name> in stack events; cleanup may DELETE_FAILED.
# Happy: add pathless grant for GetRole/DeleteRolePolicy/… → CREATE_COMPLETE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cloudformation/path-scoped-role"
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

ROLE_PATH="/app/dev/"
ROLE_PREFIX="sw-psr-${TS}"
APP_ROLE="${ROLE_PREFIX}-app"
APP_ROLE_OK="${ROLE_PREFIX}-app-ok"
DEPLOY_ROLE="${ROLE_PREFIX}-deploy"
BOUNDARY_NAME="${ROLE_PREFIX}-bound"
STACK_DENY="${ROLE_PREFIX}-deny"
STACK_OK="${ROLE_PREFIX}-ok"
BOUNDARY_ARN=""

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cfn-path-scoped-role.XXXXXX")"
cleanup() {
	export AWS_ACCESS_KEY_ID="$KEY"
	export AWS_SECRET_ACCESS_KEY="$SECRET"
	unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_DENY" >/dev/null 2>&1 || true
	aws_admin cloudformation delete-stack --stack-name "$STACK_OK" >/dev/null 2>&1 || true
	# Wait briefly so delete can finish before tearing down roles.
	sleep 2
	for r in "$APP_ROLE" "$APP_ROLE_OK" "$DEPLOY_ROLE"; do
		aws_admin iam delete-role-policy --role-name "$r" --policy-name inline >/dev/null 2>&1 || true
		aws_admin iam delete-role-policy --role-name "$r" --policy-name smoke >/dev/null 2>&1 || true
		aws_admin iam delete-role-policy --role-name "$r" --policy-name pathless >/dev/null 2>&1 || true
		for arn in $(aws_admin iam list-attached-role-policies --role-name "$r" \
			--query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
			[[ -n "$arn" && "$arn" != "None" ]] && \
				aws_admin iam detach-role-policy --role-name "$r" --policy-arn "$arn" >/dev/null 2>&1 || true
		done
		aws_admin iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	[[ -n "$BOUNDARY_ARN" ]] && aws_admin iam delete-policy --policy-arn "$BOUNDARY_ARN" >/dev/null 2>&1 || true
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

cat >"$WORKDIR/boundary.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:GetCallerIdentity",
    "Resource": "*"
  }]
}
EOF

BOUNDARY_ARN="$(aws_admin iam create-policy \
	--policy-name "$BOUNDARY_NAME" \
	--policy-document "file://${WORKDIR}/boundary.json" \
	--query Policy.Arn --output text)"

# Path-scoped only: CreateRole / PutRolePolicy on role/app/dev/* — not pathless GetRole.
cat >"$WORKDIR/path-only.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "cloudformation:*",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT}:role/app/dev/*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:CreatePolicy",
      "Resource": "*"
    }
  ]
}
EOF

# Pathless ops CFN probes before the role exists / on cleanup.
cat >"$WORKDIR/pathless.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole"
    ],
    "Resource": "arn:aws:iam::${ACCOUNT}:role/${ROLE_PREFIX}-*"
  }]
}
EOF

echo "==> create path-scoped deploy role"
aws_admin iam create-role --role-name "$DEPLOY_ROLE" \
	--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
aws_admin iam put-role-policy --role-name "$DEPLOY_ROLE" --policy-name inline \
	--policy-document "file://${WORKDIR}/path-only.json" >/dev/null

PARAMS=(
	"ParameterKey=RoleName,ParameterValue=${APP_ROLE}"
	"ParameterKey=RolePath,ParameterValue=${ROLE_PATH}"
	"ParameterKey=PermissionsBoundaryArn,ParameterValue=${BOUNDARY_ARN}"
)

echo "==> sad: create-stack as path-scoped-only role"
assume_env "arn:aws:iam::${ACCOUNT}:role/${DEPLOY_ROLE}" cfn-path-deny
aws_as cloudformation create-stack \
	--stack-name "$STACK_DENY" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters "${PARAMS[@]}" >/dev/null

ST="$(wait_stack_terminal "$STACK_DENY" 60)"
echo "    status=${ST}"
case "$ST" in
	CREATE_FAILED|*ROLLBACK*|*DELETE_FAILED*) ;;
	*)
		echo "FAIL: expected CREATE_FAILED/ROLLBACK/DELETE_FAILED, got ${ST}" >&2
		events_blob "$STACK_DENY" >&2
		exit 1
		;;
esac

BLOB="$(events_blob "$STACK_DENY")"
echo "$BLOB" | grep -qiE 'iam:GetRole' || {
	echo "FAIL: expected iam:GetRole in stack events (CFN must probe before CreateRole):" >&2
	echo "$BLOB" >&2
	exit 1
}
echo "$BLOB" | grep -qiE 'not authorized|AccessDenied' || {
	echo "FAIL: expected AccessDenied/not authorized in stack events:" >&2
	echo "$BLOB" >&2
	exit 1
}
# Pathless ARN: role/<name> without /app/dev/
PATHLESS="role/${APP_ROLE}"
PATHED="role/app/dev/${APP_ROLE}"
echo "$BLOB" | grep -q "$PATHLESS" || {
	echo "FAIL: expected pathless '${PATHLESS}' in deny reason:" >&2
	echo "$BLOB" >&2
	exit 1
}
if echo "$BLOB" | grep -q "$PATHED"; then
	# Deny must cite pathless form; pathed cite alone is the wrong shape.
	if ! echo "$BLOB" | grep -E "role/${APP_ROLE}([^/]|$)" >/dev/null; then
		echo "FAIL: deny cited only pathed ARN, not pathless role/<name>:" >&2
		echo "$BLOB" >&2
		exit 1
	fi
fi
echo "OK: path-scoped-only → iam:GetRole AccessDenied on pathless ARN"

# New-stack rollback with nothing created → ROLLBACK_COMPLETE (AWS-shaped).
# DELETE_FAILED shows up when CFN still invokes pathless DeleteRolePolicy/GetRole
# during cleanup; LocalEmu skips never-created resources, so admin-delete the
# failed stack and move on once GetRole deny is proven.
case "$ST" in
	*DELETE_FAILED*)
		echo "OK: stack already DELETE_FAILED after failed create"
		;;
	*)
		echo "OK: failed create ended ${ST} (GetRole deny proven; never-created skip)"
		;;
esac

echo "==> happy: add pathless grant, create-stack succeeds"
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
# Best-effort; don't wait — happy path uses a distinct stack/role name.
aws_admin cloudformation delete-stack --stack-name "$STACK_DENY" >/dev/null 2>&1 || true
aws_admin iam put-role-policy --role-name "$DEPLOY_ROLE" --policy-name pathless \
	--policy-document "file://${WORKDIR}/pathless.json" >/dev/null

PARAMS_OK=(
	"ParameterKey=RoleName,ParameterValue=${APP_ROLE_OK}"
	"ParameterKey=RolePath,ParameterValue=${ROLE_PATH}"
	"ParameterKey=PermissionsBoundaryArn,ParameterValue=${BOUNDARY_ARN}"
)

assume_env "arn:aws:iam::${ACCOUNT}:role/${DEPLOY_ROLE}" cfn-path-ok
aws_as cloudformation create-stack \
	--stack-name "$STACK_OK" \
	--template-body "file://${EX}/template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameters "${PARAMS_OK[@]}" >/dev/null

ST="$(wait_stack_terminal "$STACK_OK" 90)"
echo "    status=${ST}"
[[ "$ST" == "CREATE_COMPLETE" ]] || {
	echo "FAIL: expected CREATE_COMPLETE after pathless grant, got ${ST}" >&2
	events_blob "$STACK_OK" >&2
	exit 1
}

APP_ARN="$(aws_admin iam get-role --role-name "$APP_ROLE_OK" --query 'Role.Arn' --output text)"
case "$APP_ARN" in
*"role/app/dev/${APP_ROLE_OK}") ;;
*)
	echo "FAIL: created role ARN missing path: ${APP_ARN}" >&2
	exit 1
	;;
esac
echo "OK: pathless grant → CREATE_COMPLETE (role ARN includes path)"

echo "OK: cfn-path-scoped-role-smoke (${TS})"
