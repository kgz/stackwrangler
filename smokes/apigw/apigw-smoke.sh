#!/usr/bin/env bash
# Wire HTTP API → Lambda and GET the LocalEmu invoke URL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

IAM_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

# Prefer APIGW-shaped response (statusCode + body)
FN="awsbox-apigw-hello"
ZIP="$ROOT/.awsbox/lambda-apigw-hello.zip"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
path = sys.argv[1]
code = b"""exports.handler = async (event) => ({
  statusCode: 200,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ ok: true, path: event.rawPath || event.path || '/' }),
});
"""
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

aws --endpoint-url "$IAM_EP" --region "$REGION" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-role \
		--role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

if ! aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function --function-name "$FN" >/dev/null 2>&1; then
	aws --endpoint-url "$IAM_EP" --region "$REGION" lambda create-function \
		--function-name "$FN" --runtime nodejs18.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${ZIP}" >/dev/null
fi

for _ in $(seq 1 60); do
	st="$(aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function \
		--function-name "$FN" --query 'Configuration.State' --output text)"
	[[ "$st" == "Active" ]] && break
	sleep 2
done

FN_ARN="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function \
		--function-name "$FN" --query 'Configuration.FunctionArn' --output text
)"
API_NAME="awsbox-http-$(date +%s)"

API_ID="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" apigatewayv2 create-api \
		--name "$API_NAME" --protocol-type HTTP \
		--query 'ApiId' --output text
)"

INT_ID="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" apigatewayv2 create-integration \
		--api-id "$API_ID" \
		--integration-type AWS_PROXY \
		--integration-uri "$FN_ARN" \
		--payload-format-version 2.0 \
		--integration-method POST \
		--query 'IntegrationId' --output text
)"

aws --endpoint-url "$IAM_EP" --region "$REGION" apigatewayv2 create-route \
	--api-id "$API_ID" --route-key 'GET /' \
	--target "integrations/${INT_ID}" >/dev/null

aws --endpoint-url "$IAM_EP" --region "$REGION" apigatewayv2 create-stage \
	--api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null || true

aws --endpoint-url "$IAM_EP" --region "$REGION" lambda add-permission \
	--function-name "$FN" \
	--statement-id "apigw-${API_ID}" \
	--action lambda:InvokeFunction \
	--principal apigateway.amazonaws.com >/dev/null 2>&1 || true

URL="${IAM_EP}/_aws/execute-api-v2/${API_ID}/\$default/"
BODY="$(curl -sS -m 60 "$URL")"
echo "URL=${URL}"
echo "BODY=${BODY}"
echo "$BODY" | grep -q '"ok": *true\|"ok":true'
echo "OK: apigateway → ${FN} (${API_ID})"
