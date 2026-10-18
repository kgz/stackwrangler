#!/usr/bin/env bash
# Create hello Lambda (if missing) and invoke it.
# Usage: ./bin/lambda-smoke.sh [function-name]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

IAM_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

FN="${1:-awsbox-hello}"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
ZIP="$ROOT/.awsbox/lambda-hello.zip"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
path = sys.argv[1]
code = b"""exports.handler = async (event) => {
  return { ok: true, echo: event ?? null };
};
"""
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

aws --endpoint-url "$IAM_EP" --region "$REGION" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-role \
		--role-name "$ROLE_NAME" \
		--assume-role-policy-document "$TRUST" >/dev/null

if ! aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function --function-name "$FN" >/dev/null 2>&1; then
	aws --endpoint-url "$IAM_EP" --region "$REGION" lambda create-function \
		--function-name "$FN" \
		--runtime nodejs18.x \
		--role "$ROLE_ARN" \
		--handler index.handler \
		--zip-file "fileb://${ZIP}" >/dev/null
fi

echo "waiting for ${FN} Active…"
for _ in $(seq 1 60); do
	state="$(
		aws --endpoint-url "$IAM_EP" --region "$REGION" lambda get-function \
			--function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || echo Pending
	)"
	if [[ "$state" == "Active" ]]; then
		break
	fi
	sleep 2
done
if [[ "$state" != "Active" ]]; then
	echo "FAIL: function never became Active (state=${state})" >&2
	exit 1
fi

OUT="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" lambda invoke \
		--function-name "$FN" \
		--payload '{"ping":true}' \
		--cli-binary-format raw-in-base64-out \
		/tmp/awsbox-lambda-out.json \
		--query 'StatusCode' --output text
)"

BODY="$(cat /tmp/awsbox-lambda-out.json)"
echo "StatusCode=${OUT}"
echo "Payload=${BODY}"

echo "$BODY" | grep -q '"ok": *true\|"ok":true' || {
	echo "FAIL: unexpected payload" >&2
	exit 1
}
echo "OK: lambda invoke ${FN}"
