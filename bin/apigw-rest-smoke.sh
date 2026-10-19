#!/usr/bin/env bash
# REST API (v1) imported from OpenAPI: aws_proxy + REQUEST Lambda authorizer
# (examples/apigw-rest, docs/apigw-rest.md).
# Happy: public route 200 with query passthrough; good token 200 with authorizer context.
# Happy (control plane only): custom domain + root base-path mapping.
# Sad: no token 401; denied token 401 (AWS returns 403, see docs); unknown route 403.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
ACCOUNT="000000000000"
TS="$(date +%s)"
EX="$ROOT/examples/apigw-rest"
WORK="$ROOT/.awsbox/apigw-rest-${TS}"
HANDLER="awsbox-rest-handler-${TS}"
AUTHZ="awsbox-rest-authz-${TS}"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
KEEP="${AWSBOX_APIGW_REST_KEEP:-0}"
API_ID=""
DOMAIN="api-${TS}.example.test"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	aws apigateway delete-base-path-mapping --domain-name "$DOMAIN" --base-path '(none)' >/dev/null 2>&1 || true
	aws apigateway delete-domain-name --domain-name "$DOMAIN" >/dev/null 2>&1 || true
	[[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$HANDLER" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$AUTHZ" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$WORK"
python3 - "$EX" "$WORK" <<'PY'
import sys, zipfile
ex, work = sys.argv[1], sys.argv[2]
for name in ("handler", "authorizer"):
    with zipfile.ZipFile(f"{work}/{name}.zip", "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.write(f"{ex}/{name}.js", "index.js")
PY

aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

for pair in "$HANDLER:handler" "$AUTHZ:authorizer"; do
	aws lambda create-function --function-name "${pair%%:*}" --runtime nodejs20.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${WORK}/${pair##*:}.zip" >/dev/null
done
for fn in "$HANDLER" "$AUTHZ"; do
	for _ in $(seq 1 60); do
		[[ "$(aws lambda get-function --function-name "$fn" --query Configuration.State --output text)" == "Active" ]] && break
		sleep 2
	done
done

uri() {
	echo "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT}:function:$1/invocations"
}
AUTHORIZER_URI="$(uri "$AUTHZ")" HANDLER_URI="$(uri "$HANDLER")" \
	python3 -c 'import os,sys; t=open(sys.argv[1]).read(); print(t.replace("${AUTHORIZER_URI}", os.environ["AUTHORIZER_URI"]).replace("${HANDLER_URI}", os.environ["HANDLER_URI"]))' \
	"$EX/openapi.template.json" >"$WORK/openapi.json"

API_ID="$(aws apigateway import-rest-api --body "fileb://${WORK}/openapi.json" --query id --output text)"

# Same grants real API Gateway needs to call the functions.
for fn in "$HANDLER" "$AUTHZ"; do
	aws lambda add-permission --function-name "$fn" --statement-id "apigw-${TS}" --action lambda:InvokeFunction \
		--principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*" >/dev/null
done

AUTH_TYPE="$(aws apigateway get-authorizers --rest-api-id "$API_ID" --query 'items[0].type' --output text)"
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name local >/dev/null
BASE="${EP}/restapis/${API_ID}/local/_user_request_"

FAIL=0
check() {
	local label="$1" want="$2" got="$3" body="${4:-}"
	if [[ "$got" == "$want" ]]; then
		echo "ok   ${label}: ${got}"
	else
		echo "FAIL ${label}: got ${got}, want ${want} ${body}" >&2
		FAIL=1
	fi
}
req() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }

check "authorizer imported as REQUEST" "REQUEST" "$AUTH_TYPE"

code="$(req "${BASE}/public/callback?code=abc&state=xyz")"
check "happy public route (no authorizer)" 200 "$code" "$(cat "$WORK/body")"
check "happy query passthrough" "abc/xyz" "$(python3 -c 'import json,sys; q=json.load(open(sys.argv[1]))["query"]; print(q["code"] + "/" + q["state"])' "$WORK/body" 2>/dev/null || echo bad-body)"

code="$(req "${BASE}/v1/items")"
check "sad no token" 401 "$code"

code="$(req -H 'Authorization: Bearer bad' "${BASE}/v1/items")"
check "sad denied token (AWS: 403, emulator: 401)" 401 "$code"

code="$(req -H 'Authorization: Bearer good' "${BASE}/v1/items")"
check "happy allowed token" 200 "$code" "$(cat "$WORK/body")"
check "happy authorizer context reaches handler" "demo-tenant" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["authorizer"]["tenant"])' "$WORK/body" 2>/dev/null || echo missing)"

code="$(req "${BASE}/nope")"
check "sad unknown route" 403 "$code"

# Custom domain + root base-path mapping (what serverless-domain-manager sets up).
CERT="$(aws acm request-certificate --domain-name "$DOMAIN" --query CertificateArn --output text)"
aws apigateway create-domain-name --domain-name "$DOMAIN" --regional-certificate-arn "$CERT" \
	--endpoint-configuration types=REGIONAL >/dev/null
aws apigateway create-base-path-mapping --domain-name "$DOMAIN" --rest-api-id "$API_ID" --stage local >/dev/null
check "happy custom domain created (control plane)" "$DOMAIN" "$(aws apigateway get-domain-name --domain-name "$DOMAIN" --query domainName --output text)"
check "happy root base-path mapping (control plane)" "$API_ID" "$(aws apigateway get-base-path-mappings --domain-name "$DOMAIN" --query 'items[0].restApiId' --output text)"
# Requests are NOT routed by custom domain locally (they fall through to S3); see docs/apigw-rest.md.

[[ "$FAIL" == "0" ]] || exit 1
echo "OK: REST API from OpenAPI with REQUEST authorizer (${API_ID})"
