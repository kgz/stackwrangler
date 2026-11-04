#!/usr/bin/env bash
# Deploy a zip via UpdateFunctionCode / CreateFunction.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

IAM_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

FN="awsbox-zip-$(date +%s)"
ZIP="$ROOT/.awsbox/lambda-deploy-smoke.zip"
mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
path = sys.argv[1]
code = b"""exports.handler = async (event) => ({ deployed: true, echo: event ?? null });
"""
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws --endpoint-url "$IAM_EP" --region "$REGION" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-role \
		--role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

aws --endpoint-url "$IAM_EP" --region "$REGION" lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP}" >/dev/null

for _ in $(seq 1 60); do
	st="$(aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function \
		--function-name "$FN" --query 'Configuration.State' --output text)"
	[[ "$st" == "Active" ]] && break
	sleep 2
done

# redeploy same zip (update path)
aws --endpoint-url "$IAM_EP" --region "$REGION" lambda update-function-code \
	--function-name "$FN" --zip-file "fileb://${ZIP}" >/dev/null

for _ in $(seq 1 60); do
	st="$(aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function \
		--function-name "$FN" --query 'Configuration.State' --output text)"
	[[ "$st" == "Active" ]] && break
	sleep 2
done

aws --endpoint-url "$IAM_EP" --region "$REGION" lambda invoke \
	--function-name "$FN" \
	--payload '{"from":"deploy-smoke"}' \
	--cli-binary-format raw-in-base64-out \
	/tmp/awsbox-deploy-out.json >/dev/null

grep -q '"deployed": *true\|"deployed":true' /tmp/awsbox-deploy-out.json
echo "OK: deploy zip ${FN}"
cat /tmp/awsbox-deploy-out.json
echo
