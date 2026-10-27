#!/usr/bin/env bash
# Account A trusts into a role in B; C is denied. A's bucket is hidden from B.
# Server env (restart localemu after changing):
#   AWSBOX_ACCOUNT_IDS=awsbox-a=111111111111,awsbox-b=222222222222,awsbox-c=333333333333
#   MOTO_S3_ALLOW_CROSSACCOUNT_ACCESS=false
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_MULTI_ACCOUNT_KEEP:-0}"

ACCOUNT_A="111111111111"
ACCOUNT_B="222222222222"
ACCOUNT_C="333333333333"
KEY_A="awsbox-a"
KEY_B="awsbox-b"
KEY_C="awsbox-c"
EXT_ID="awsbox-ext"

BUCKET_A="awsbox-ma-a-${TS}"
BUCKET_B="awsbox-ma-b-${TS}"
ROLE="awsbox-cross-${TS}"
ROLE_ORG="awsbox-orgcond-${TS}"
ROLE_A="awsbox-only-a-${TS}"
USER="awsbox-assumer-${TS}"
USER_DENY="awsbox-noassume-${TS}"
ROLE_ARN=""
ASSUMER_KEY=""
DENY_KEY=""

unset AWS_PROFILE AWS_SESSION_TOKEN || true
export AWS_DEFAULT_REGION="$REGION"

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

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$ASSUMER_KEY" ]]; then
		aws_as "$KEY_A" "$SECRET" "" iam delete-access-key --user-name "$USER" --access-key-id "$ASSUMER_KEY" >/dev/null 2>&1 || true
	fi
	if [[ -n "$DENY_KEY" ]]; then
		aws_as "$KEY_A" "$SECRET" "" iam delete-access-key --user-name "$USER_DENY" --access-key-id "$DENY_KEY" >/dev/null 2>&1 || true
	fi
	aws_as "$KEY_A" "$SECRET" "" iam delete-user-policy --user-name "$USER" --policy-name allow-assume >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" iam delete-user --user-name "$USER_DENY" >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" iam delete-role --role-name "$ROLE_A" >/dev/null 2>&1 || true
	aws_as "$KEY_B" "$SECRET" "" iam delete-role-policy --role-name "$ROLE" --policy-name allow-list >/dev/null 2>&1 || true
	aws_as "$KEY_B" "$SECRET" "" iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws_as "$KEY_B" "$SECRET" "" iam delete-role --role-name "$ROLE_ORG" >/dev/null 2>&1 || true
	aws_as "$KEY_A" "$SECRET" "" s3api delete-bucket --bucket "$BUCKET_A" >/dev/null 2>&1 || true
	aws_as "$KEY_B" "$SECRET" "" s3api delete-bucket --bucket "$BUCKET_B" >/dev/null 2>&1 || true
}
trap cleanup EXIT

account_of() {
	aws_as "$1" "$SECRET" "" sts get-caller-identity --query Account --output text
}

expect_denied() {
	local desc="$1"
	shift
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		echo "$out" >&2
		fail "$desc succeeded"
	fi
	# HeadBucket is a HEAD, so the CLI prints "403 Forbidden" and drops the AccessDenied body.
	if ! echo "$out" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation|InvalidAccessKeyId|AllAccessDisabled|Forbidden|\(403\)'; then
		echo "$out" >&2
		fail "$desc was not AccessDenied"
	fi
	echo "OK: $desc"
}

echo "endpoint $EP"

got="$(account_of "$KEY_A" 2>/dev/null || true)"
if [[ "$got" != "$ACCOUNT_A" ]]; then
	fail "key ${KEY_A} is account '${got:-<error>}', want ${ACCOUNT_A}.
Set AWSBOX_ACCOUNT_IDS=${KEY_A}=${ACCOUNT_A},${KEY_B}=${ACCOUNT_B},${KEY_C}=${ACCOUNT_C} and MOTO_S3_ALLOW_CROSSACCOUNT_ACCESS=false on LocalEmu, then recreate it (docs/multi-account.md)."
fi
got="$(account_of "$KEY_B")"
[[ "$got" == "$ACCOUNT_B" ]] || fail "key ${KEY_B} is account ${got}, want ${ACCOUNT_B}"
got="$(account_of "$KEY_C")"
[[ "$got" == "$ACCOUNT_C" ]] || fail "key ${KEY_C} is account ${got}, want ${ACCOUNT_C}"
echo "OK: key→account A=${ACCOUNT_A} B=${ACCOUNT_B} C=${ACCOUNT_C}"

aws_as "$KEY_A" "$SECRET" "" s3api create-bucket --bucket "$BUCKET_A" >/dev/null
aws_as "$KEY_B" "$SECRET" "" s3api create-bucket --bucket "$BUCKET_B" >/dev/null

names="$(aws_as "$KEY_B" "$SECRET" "" s3api list-buckets --query 'Buckets[].Name' --output text)"
if echo "$names" | grep -qw "$BUCKET_A"; then
	fail "account B listed ${BUCKET_A}"
fi
if ! echo "$names" | grep -qw "$BUCKET_B"; then
	fail "account B did not list ${BUCKET_B}"
fi
expect_denied "B head-bucket on A's bucket" \
	aws_as "$KEY_B" "$SECRET" "" s3api head-bucket --bucket "$BUCKET_A"
names="$(aws_as "$KEY_A" "$SECRET" "" s3api list-buckets --query 'Buckets[].Name' --output text)"
if echo "$names" | grep -qw "$BUCKET_B"; then
	fail "account A listed ${BUCKET_B}"
fi
echo "OK: S3 in A is hidden from B"

TRUST_A="$(mktemp)"
TRUST_B="$(mktemp)"
USER_POL="$(mktemp)"
ROLE_POL="$(mktemp)"
trap 'cleanup; rm -f "$TRUST_A" "$TRUST_B" "$USER_POL" "$ROLE_POL"' EXIT

cat >"$TRUST_A" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_A}:root" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat >"$TRUST_B" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_A}:root" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "${EXT_ID}" } }
  }]
}
EOF

cat >"$USER_POL" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "*"
  }]
}
EOF

cat >"$ROLE_POL" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:ListAllMyBuckets",
    "Resource": "*"
  }]
}
EOF

ORG_TRUST="$(mktemp)"
trap 'cleanup; rm -f "$TRUST_A" "$TRUST_B" "$USER_POL" "$ROLE_POL" "$ORG_TRUST"' EXIT
cat >"$ORG_TRUST" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_A}:root" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "aws:PrincipalOrgID": "o-not-evaluated" } }
  }]
}
EOF

aws_as "$KEY_A" "$SECRET" "" iam create-role --role-name "$ROLE_A" --assume-role-policy-document "file://${TRUST_A}" >/dev/null
aws_as "$KEY_B" "$SECRET" "" iam create-role --role-name "$ROLE" --assume-role-policy-document "file://${TRUST_B}" >/dev/null
aws_as "$KEY_B" "$SECRET" "" iam create-role --role-name "$ROLE_ORG" --assume-role-policy-document "file://${ORG_TRUST}" >/dev/null
aws_as "$KEY_B" "$SECRET" "" iam put-role-policy --role-name "$ROLE" --policy-name allow-list --policy-document "file://${ROLE_POL}" >/dev/null

ROLE_ARN="$(aws_as "$KEY_B" "$SECRET" "" iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
case "$ROLE_ARN" in
	*"${ACCOUNT_B}"*) ;;
	*) fail "role ARN ${ROLE_ARN} is not in account B" ;;
esac

b_roles="$(aws_as "$KEY_B" "$SECRET" "" iam list-roles --query 'Roles[].RoleName' --output text)"
if echo "$b_roles" | grep -qw "$ROLE_A"; then
	fail "account B listed role ${ROLE_A}"
fi
a_roles="$(aws_as "$KEY_A" "$SECRET" "" iam list-roles --query 'Roles[].RoleName' --output text)"
if echo "$a_roles" | grep -qw "$ROLE"; then
	fail "account A listed role ${ROLE}"
fi
echo "OK: IAM roles stay in their account"

aws_as "$KEY_A" "$SECRET" "" iam create-user --user-name "$USER" >/dev/null
aws_as "$KEY_A" "$SECRET" "" iam put-user-policy --user-name "$USER" --policy-name allow-assume --policy-document "file://${USER_POL}" >/dev/null
keys_json="$(aws_as "$KEY_A" "$SECRET" "" iam create-access-key --user-name "$USER" --output json)"
ASSUMER_KEY="$(echo "$keys_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
ASSUMER_SECRET="$(echo "$keys_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

aws_as "$KEY_A" "$SECRET" "" iam create-user --user-name "$USER_DENY" >/dev/null
deny_json="$(aws_as "$KEY_A" "$SECRET" "" iam create-access-key --user-name "$USER_DENY" --output json)"
DENY_KEY="$(echo "$deny_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENY_SECRET="$(echo "$deny_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

got="$(aws_as "$ASSUMER_KEY" "$ASSUMER_SECRET" "" sts get-caller-identity --query Account --output text)"
[[ "$got" == "$ACCOUNT_A" ]] || fail "assumer key is account ${got}, want ${ACCOUNT_A}"

expect_denied "A without ExternalId" \
	aws_as "$KEY_A" "$SECRET" "" sts assume-role --role-arn "$ROLE_ARN" --role-session-name from-a
expect_denied "C with ExternalId" \
	aws_as "$KEY_C" "$SECRET" "" sts assume-role --role-arn "$ROLE_ARN" --role-session-name from-c --external-id "$EXT_ID"
expect_denied "A user without sts:AssumeRole" \
	aws_as "$DENY_KEY" "$DENY_SECRET" "" sts assume-role --role-arn "$ROLE_ARN" --role-session-name no-policy --external-id "$EXT_ID"

org_arn="$(aws_as "$KEY_B" "$SECRET" "" iam get-role --role-name "$ROLE_ORG" --query 'Role.Arn' --output text)"
expect_denied "unknown trust condition does not allow" \
	aws_as "$KEY_A" "$SECRET" "" sts assume-role --role-arn "$org_arn" --role-session-name org

creds="$(aws_as "$ASSUMER_KEY" "$ASSUMER_SECRET" "" sts assume-role --role-arn "$ROLE_ARN" --role-session-name from-a --external-id "$EXT_ID" --output json)"
sess_key="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')"
sess_secret="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')"
sess_token="$(echo "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])')"

ident="$(aws_as "$sess_key" "$sess_secret" "$sess_token" sts get-caller-identity --output json)"
sess_account="$(echo "$ident" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')"
sess_arn="$(echo "$ident" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])')"
[[ "$sess_account" == "$ACCOUNT_B" ]] || fail "assumed session account ${sess_account}, want ${ACCOUNT_B}"
case "$sess_arn" in
	arn:aws:sts::"${ACCOUNT_B}":assumed-role/"${ROLE}"/*) ;;
	*) fail "assumed session arn ${sess_arn}" ;;
esac
echo "OK: user in A assumed role in B"

seen="$(aws_as "$sess_key" "$sess_secret" "$sess_token" s3api list-buckets --query 'Buckets[].Name' --output text)"
if echo "$seen" | grep -qw "$BUCKET_A"; then
	fail "assumed role in B listed ${BUCKET_A}"
fi
if ! echo "$seen" | grep -qw "$BUCKET_B"; then
	fail "assumed role in B did not list ${BUCKET_B}"
fi
echo "OK: assumed role sees B, not A"
echo "multi-account smoke passed"
