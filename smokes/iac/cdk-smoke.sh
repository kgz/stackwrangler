#!/usr/bin/env bash
# Synth examples/cdk/s3-lambda and deploy via LocalEmu CloudFormation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cdk/s3-lambda"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
BUCKET="awsbox-cdk-${TS}"
FN="awsbox-cdk-writer-${TS}"
CODE_BUCKET="awsbox-cdk-code-${TS}"
STACK="awsbox-cdk-s3-lambda-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"
export CDK_DEFAULT_ACCOUNT=000000000000
export CDK_DEFAULT_REGION="${AWS_DEFAULT_REGION}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

cd "$EX"
if [[ ! -d node_modules ]]; then
	npm install --no-fund --no-audit
fi

npx cdk synth --quiet -o "$EX/cdk.out"
TEMPLATE="$EX/cdk.out/AwsboxCdkS3Lambda.template.json"
[[ -f "$TEMPLATE" ]] || {
	echo "error: missing synth output $TEMPLATE" >&2
	exit 1
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
	--template-file "$TEMPLATE" \
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
	--payload '{"source":"cdk-smoke"}' \
	--cli-binary-format raw-in-base64-out \
	/tmp/awsbox-cdk-out.json >/dev/null

cat /tmp/awsbox-cdk-out.json
echo
grep -q '"ok": *true\|"ok":true' /tmp/awsbox-cdk-out.json

LIST="$(aws s3 ls "s3://${BUCKET}/writes/" || true)"
echo "$LIST"
echo "$LIST" | grep -q .

echo "OK: cdk→cfn S3+Lambda (${STACK} / ${BUCKET} / ${FN})"
