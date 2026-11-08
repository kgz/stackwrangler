#!/usr/bin/env bash
# Role-addressed IAM actions authorise against the full role ARN including path (#647).
# Happy: policy on role/team/app/* allows GetRole / PutRolePolicy / CreateRole / … on that path.
# Sad: policy on role/other/path/* still denies (stored role + CreateRole request Path).
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
ACCT="000000000000"
TARGET="awsbox-rp-tgt-${TS}"
CREATED="awsbox-rp-created-${TS}"
DENY_CREATE="awsbox-rp-dencreate-${TS}"
CALLER="awsbox-rp-caller-${TS}"
WRONG="awsbox-rp-wrong-${TS}"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
KEEP="${AWSBOX_IAM_ROLE_PATH_KEEP:-0}"

PATH_ACTIONS='["iam:CreateRole","iam:GetRole","iam:ListRolePolicies","iam:ListAttachedRolePolicies","iam:TagRole","iam:UntagRole","iam:PutRolePolicy","iam:GetRolePolicy","iam:DeleteRolePolicy","iam:DeleteRole","iam:UpdateRole","iam:UpdateAssumeRolePolicy","iam:AttachRolePolicy","iam:DetachRolePolicy","iam:PutRolePermissionsBoundary","iam:DeleteRolePermissionsBoundary"]'

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	for role in "$CALLER" "$WRONG" "$TARGET" "$CREATED" "$DENY_CREATE"; do
		[[ -z "$role" ]] && continue
		aws iam delete-role-policy --role-name "$role" --policy-name p >/dev/null 2>&1 || true
		aws iam delete-role-policy --role-name "$role" --policy-name smoke >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

expect_allow() {
	local label="$1"
	shift
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || {
		echo "FAIL: ${label} denied/failed: ${out}" >&2
		exit 1
	}
	echo "OK: ${label}"
}

expect_deny() {
	local label="$1"
	local arn_needle="$2"
	shift 2
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || {
		echo "FAIL: ${label} succeeded" >&2
		echo "$out" >&2
		exit 1
	}
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny' <<<"$out" \
		|| {
			echo "FAIL: ${label}: ${out}" >&2
			exit 1
		}
	# Denial must cite the pathed ARN, not role/<name> alone.
	grep -q "$arn_needle" <<<"$out" \
		|| {
			echo "FAIL: ${label}: AccessDenied missing '${arn_needle}': ${out}" >&2
			exit 1
		}
	echo "OK: ${label}"
}

AT='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'"$ACCT"':root"},"Action":"sts:AssumeRole"}]}'

aws iam create-role --path /team/app/ --role-name "$TARGET" --assume-role-policy-document "$AT" >/dev/null
TARGET_ARN="$(aws iam get-role --role-name "$TARGET" --query 'Role.Arn' --output text)"
case "$TARGET_ARN" in
*"role/team/app/${TARGET}") ;;
*)
	echo "FAIL: get-role ARN missing path: ${TARGET_ARN}" >&2
	exit 1
	;;
esac

aws iam create-role --role-name "$CALLER" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$CALLER" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":${PATH_ACTIONS},\"Resource\":\"arn:aws:iam::${ACCT}:role/team/app/*\"}]}" \
	>/dev/null

aws iam create-role --role-name "$WRONG" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$WRONG" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":${PATH_ACTIONS},\"Resource\":\"arn:aws:iam::${ACCT}:role/other/path/*\"}]}" \
	>/dev/null

CREDS="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${CALLER}" --role-session-name rp-ok --output json)"
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

expect_allow "GetRole via path Allow" aws iam get-role --role-name "$TARGET"
expect_allow "ListRolePolicies via path Allow" aws iam list-role-policies --role-name "$TARGET"
expect_allow "TagRole via path Allow" aws iam tag-role --role-name "$TARGET" --tags Key=env,Value=smoke
expect_allow "PutRolePolicy via path Allow" aws iam put-role-policy --role-name "$TARGET" --policy-name smoke \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}'
expect_allow "GetRolePolicy via path Allow" aws iam get-role-policy --role-name "$TARGET" --policy-name smoke
expect_allow "DeleteRolePolicy via path Allow" aws iam delete-role-policy --role-name "$TARGET" --policy-name smoke

# CreateRole authz uses request Path (role does not exist yet — Path fallback in _iam_role_arn).
expect_allow "CreateRole via request Path Allow" aws iam create-role \
	--path /team/app/ --role-name "$CREATED" --assume-role-policy-document "$AT"
CREATED_ARN="$(aws iam get-role --role-name "$CREATED" --query 'Role.Arn' --output text)"
case "$CREATED_ARN" in
*"role/team/app/${CREATED}") ;;
*)
	echo "FAIL: CreateRole ARN missing path: ${CREATED_ARN}" >&2
	exit 1
	;;
esac
echo "OK: CreateRole stored ARN includes path"

unset AWS_SESSION_TOKEN
export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"

CREDS="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${WRONG}" --role-session-name rp-bad --output json)"
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

expect_deny "GetRole wrong path denied" "role/team/app/${TARGET}" \
	aws iam get-role --role-name "$TARGET"
expect_deny "PutRolePolicy wrong path denied" "role/team/app/${TARGET}" \
	aws iam put-role-policy --role-name "$TARGET" --policy-name nope \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}'
expect_deny "CreateRole wrong path denied" "role/team/app/${DENY_CREATE}" \
	aws iam create-role --path /team/app/ --role-name "$DENY_CREATE" --assume-role-policy-document "$AT"

echo "iam-role-path-arn-smoke: PASS"
