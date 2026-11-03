#!/usr/bin/env bash
# Package examples/sam/s3-lambda and deploy packaged CFN to LocalEmu.
# Uses packaged-template.yaml so SAM CLI is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/sam/s3-lambda"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
BUCKET="awsbox-sam-${TS}"
FN="awsbox-sam-writer-${TS}"
CODE_BUCKET="awsbox-sam-code-${TS}"
STACK="awsbox-sam-s3-lambda-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

mkdir -p "$EX/build"
(
	cd "$EX/src"
	zip -q "$EX/build/function.zip" index.js
)

aws s3 mb "s3://${CODE_BUCKET}"
aws s3 cp "$EX/build/function.zip" "s3://${CODE_BUCKET}/function.zip"

aws cloudformation deploy \
	--stack-name "$STACK" \
	--template-file "$EX/packaged-template.yaml" \
	--capabilities CAPABILITY_NAMED_IAM \
	--parameter-overrides \
	"BucketName=${BUCKET}" \
	"FunctionName=${FN}" \
	"CodeBucket=${CODE_BUCKET}" \
	"CodeKey=function.zip"

echo "waiting for ${FN} Active…"
for _ in $(seq 1 60); do
	st="$(aws lambda get-function --function-name "$FN" \
		--query 'Configuration.State' --output text 2>/dev/null || echo Pending)"
	[[ "$st" == "Active" ]] && break
	sleep 2
done

aws lambda invoke \
	--function-name "$FN" \
	--payload '{"source":"sam-smoke"}' \
	--cli-binary-format raw-in-base64-out \
	/tmp/awsbox-sam-out.json >/dev/null

cat /tmp/awsbox-sam-out.json
echo
grep -q '"ok": *true\|"ok":true' /tmp/awsbox-sam-out.json

LIST="$(aws s3 ls "s3://${BUCKET}/writes/" || true)"
echo "$LIST"
echo "$LIST" | grep -q .

echo "OK: sam→cfn S3+Lambda (${STACK} / ${BUCKET} / ${FN})"
