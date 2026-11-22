#!/usr/bin/env bash
# API Gateway management IAM beyond /apikeys + /usageplans (#311 / from #294).
#
# Happy: Serverless/CDK-style deploy role scoped to one REST API can
#   create-deployment, create-stage, create-authorizer on that API;
#   PUT /tags/* can tag an API key; POST /domainnames and v2 POST /apis when allowed.
# Sad: same role denied on another REST API; denied on /domainnames and v2 /apis
#   without those resources; role without apigateway:PUT on /tags/* cannot tag a key.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${AWSBOX_APIGW_KEEP:-0}"
AGW="arn:aws:apigateway:${REGION}::"
ACCOUNT=""
API_A=""
API_B=""
KEY_ID=""
DOMAIN="iam-${TS}.apigw.local"
CERT=""
DEPLOY_ROLE="awsbox-apigw-deploy-${TS}"
TAGS_ROLE="awsbox-apigw-tags-${TS}"
NOTAGS_ROLE="awsbox-apigw-notags-${TS}"
DOMAIN_ROLE="awsbox-apigw-domain-${TS}"
V2_ROLE="awsbox-apigw-v2-${TS}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/apigw-iam.XXXXXX")"
V2_API=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws_admin() {
	unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
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

expect_deny() {
	local label="$1"
	shift
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || {
		echo "FAIL: ${label}: expected deny, succeeded: ${out}" >&2
		return 1
	}
	echo "$out" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Forbidden' || {
		echo "FAIL: ${label}: expected AccessDenied-class error: ${out}" >&2
		return 1
	}
	echo "ok   sad ${label}"
}

expect_ok() {
	local label="$1"
	shift
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || {
		echo "FAIL: ${label}: expected success: ${out}" >&2
		return 1
	}
	echo "ok   happy ${label}" >&2
	# Emit CLI --query/--output text (or full body) for callers that capture stdout.
	printf '%s\n' "$out"
}

cleanup() {
	unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
	export AWS_ACCESS_KEY_ID="$KEY"
	export AWS_SECRET_ACCESS_KEY="$SECRET"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$V2_API" ]] && aws_admin apigatewayv2 delete-api --api-id "$V2_API" >/dev/null 2>&1 || true
	[[ -n "$KEY_ID" ]] && aws_admin apigateway delete-api-key --api-key "$KEY_ID" >/dev/null 2>&1 || true
	[[ -n "$DOMAIN" ]] && aws_admin apigateway delete-domain-name --domain-name "$DOMAIN" >/dev/null 2>&1 || true
	[[ -n "$CERT" ]] && aws_admin acm delete-certificate --certificate-arn "$CERT" >/dev/null 2>&1 || true
	[[ -n "$API_A" ]] && aws_admin apigateway delete-rest-api --rest-api-id "$API_A" >/dev/null 2>&1 || true
	[[ -n "$API_B" ]] && aws_admin apigateway delete-rest-api --rest-api-id "$API_B" >/dev/null 2>&1 || true
	for r in "$DEPLOY_ROLE" "$TAGS_ROLE" "$NOTAGS_ROLE" "$DOMAIN_ROLE" "$V2_ROLE"; do
		aws_admin iam delete-role-policy --role-name "$r" --policy-name inline >/dev/null 2>&1 || true
		aws_admin iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

ACCOUNT="$(aws_admin sts get-caller-identity --query Account --output text 2>/dev/null || echo 000000000000)"

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

mk_role() {
	local name="$1" policy_file="$2"
	aws_admin iam create-role --role-name "$name" \
		--assume-role-policy-document "file://${WORKDIR}/trust.json" >/dev/null
	aws_admin iam put-role-policy --role-name "$name" --policy-name inline \
		--policy-document "file://${policy_file}" >/dev/null
}

echo "==> admin: two REST APIs + API key fixture"
API_A="$(aws_admin apigateway create-rest-api --name "iam-a-${TS}" --query id --output text)"
API_B="$(aws_admin apigateway create-rest-api --name "iam-b-${TS}" --query id --output text)"
KEY_ID="$(aws_admin apigateway create-api-key --name "iam-key-${TS}" --enabled --query id --output text)"
KEY_ARN="${AGW}/apikeys/${KEY_ID}"

# Deploy role: one REST API only (Serverless/CDK deploy-role shape).
cat >"$WORKDIR/deploy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE"
    ],
    "Resource": [
      "${AGW}/restapis/${API_A}",
      "${AGW}/restapis/${API_A}/*"
    ]
  }]
}
EOF
mk_role "$DEPLOY_ROLE" "$WORKDIR/deploy.json"

# Tags: allow everything on apikeys except PUT /tags (deny tags via omission).
cat >"$WORKDIR/notags.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["apigateway:GET", "apigateway:POST", "apigateway:PATCH", "apigateway:DELETE"],
    "Resource": ["${AGW}/apikeys", "${AGW}/apikeys/*"]
  }]
}
EOF
mk_role "$NOTAGS_ROLE" "$WORKDIR/notags.json"

cat >"$WORKDIR/tags.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["apigateway:GET", "apigateway:POST", "apigateway:PATCH", "apigateway:DELETE"],
      "Resource": ["${AGW}/apikeys", "${AGW}/apikeys/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["apigateway:GET", "apigateway:PUT"],
      "Resource": ["${AGW}/tags", "${AGW}/tags/*"]
    }
  ]
}
EOF
mk_role "$TAGS_ROLE" "$WORKDIR/tags.json"

cat >"$WORKDIR/domain.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"],
    "Resource": ["${AGW}/domainnames", "${AGW}/domainnames/*"]
  }]
}
EOF
mk_role "$DOMAIN_ROLE" "$WORKDIR/domain.json"

cat >"$WORKDIR/v2.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"],
    "Resource": ["${AGW}/apis", "${AGW}/apis/*"]
  }]
}
EOF
mk_role "$V2_ROLE" "$WORKDIR/v2.json"

DEPLOY_ARN="arn:aws:iam::${ACCOUNT}:role/${DEPLOY_ROLE}"
TAGS_ARN="arn:aws:iam::${ACCOUNT}:role/${TAGS_ROLE}"
NOTAGS_ARN="arn:aws:iam::${ACCOUNT}:role/${NOTAGS_ROLE}"
DOMAIN_ARN="arn:aws:iam::${ACCOUNT}:role/${DOMAIN_ROLE}"
V2_ARN="arn:aws:iam::${ACCOUNT}:role/${V2_ROLE}"
AUTHZ_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT}:function:awsbox-iam-authz-dummy/invocations"

echo "==> deploy role: allow on API_A (deployments / stages / authorizers)"
assume_env "$DEPLOY_ARN" apigw-deploy
DEP_ID="$(expect_ok "create-deployment on scoped REST API" \
	aws_as apigateway create-deployment --rest-api-id "$API_A" --description "iam-${TS}" \
	--query id --output text | tail -1 | tr -d '[:space:]')"
[[ -n "$DEP_ID" && "$DEP_ID" != "None" ]] || {
	echo "FAIL: empty deployment id from scoped create-deployment" >&2
	exit 1
}
expect_ok "create-stage on scoped REST API" \
	aws_as apigateway create-stage --rest-api-id "$API_A" --stage-name "iam-${TS}" \
	--deployment-id "$DEP_ID"
expect_ok "create-authorizer on scoped REST API" \
	aws_as apigateway create-authorizer --rest-api-id "$API_A" --name "iam-authz-${TS}" \
	--type TOKEN --authorizer-uri "$AUTHZ_URI" \
	--identity-source 'method.request.header.Authorization'

echo "==> deploy role: deny on API_B + domainnames + v2 /apis"
expect_deny "create-deployment on other REST API" \
	aws_as apigateway create-deployment --rest-api-id "$API_B" --description "should-deny"
expect_deny "create-authorizer on other REST API" \
	aws_as apigateway create-authorizer --rest-api-id "$API_B" --name "deny-authz-${TS}" \
	--type TOKEN --authorizer-uri "$AUTHZ_URI" \
	--identity-source 'method.request.header.Authorization'
expect_deny "create-domain-name without /domainnames" \
	aws_as apigateway create-domain-name --domain-name "$DOMAIN" \
	--endpoint-configuration types=REGIONAL
expect_deny "apigatewayv2 create-api without /apis" \
	aws_as apigatewayv2 create-api --name "deny-v2-${TS}" --protocol-type HTTP

echo "==> tags: PUT /tags/* required to tag an API key"
assume_env "$NOTAGS_ARN" apigw-notags
expect_deny "tag-resource without apigateway:PUT on /tags/*" \
	aws_as apigateway tag-resource --resource-arn "$KEY_ARN" --tags "env=denied-${TS}"

assume_env "$TAGS_ARN" apigw-tags
expect_ok "tag-resource with apigateway:PUT on /tags/*" \
	aws_as apigateway tag-resource --resource-arn "$KEY_ARN" --tags "env=ok-${TS}"
TAG_VAL="$(aws_as apigateway get-tags --resource-arn "$KEY_ARN" --query "tags.env" --output text)"
[[ "$TAG_VAL" == "ok-${TS}" ]] || {
	echo "FAIL: expected tag env=ok-${TS}, got ${TAG_VAL}" >&2
	exit 1
}
echo "ok   happy get-tags after PUT /tags"

echo "==> domainnames role can create-domain-name"
CERT="$(aws_admin acm request-certificate --domain-name "$DOMAIN" --query CertificateArn --output text)"
assume_env "$DOMAIN_ARN" apigw-domain
expect_ok "create-domain-name with /domainnames allow" \
	aws_as apigateway create-domain-name --domain-name "$DOMAIN" \
	--regional-certificate-arn "$CERT" --endpoint-configuration types=REGIONAL

echo "==> v2 /apis role can create-api"
assume_env "$V2_ARN" apigw-v2
V2_API="$(expect_ok "apigatewayv2 create-api with /apis allow" \
	aws_as apigatewayv2 create-api --name "ok-v2-${TS}" --protocol-type HTTP \
	--query ApiId --output text | tail -1 | tr -d '[:space:]')"
[[ -n "$V2_API" && "$V2_API" != "None" ]] || {
	echo "FAIL: empty ApiId from allowed v2 create-api" >&2
	exit 1
}

echo "OK: apigw-iam-smoke (API_A=${API_A} API_B=${API_B} deploy-role=${DEPLOY_ROLE})"
