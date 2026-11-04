#!/usr/bin/env bash
# Apply examples/terraform/s3-lambda and prove Lambda wrote an object.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/terraform/s3-lambda"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
BUCKET="awsbox-iac-$(date +%s)"
FN="awsbox-iac-writer-$(date +%s)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

mkdir -p "$EX/build"
cd "$EX"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="bucket_name=${BUCKET}" \
	-var="function_name=${FN}"

echo "waiting for ${FN} Active…"
for _ in $(seq 1 60); do
	st="$(aws --endpoint-url "$EP" lambda get-function --function-name "$FN" \
		--query 'Configuration.State' --output text 2>/dev/null || echo Pending)"
	[[ "$st" == "Active" ]] && break
	sleep 2
done

aws --endpoint-url "$EP" lambda invoke \
	--function-name "$FN" \
	--payload '{"source":"iac-smoke"}' \
	--cli-binary-format raw-in-base64-out \
	/tmp/awsbox-iac-out.json >/dev/null

cat /tmp/awsbox-iac-out.json
echo
grep -q '"ok": *true\|"ok":true' /tmp/awsbox-iac-out.json

# list objects Lambda wrote
LIST="$(aws --endpoint-url "$EP" s3 ls "s3://${BUCKET}/writes/" || true)"
echo "$LIST"
echo "$LIST" | grep -q .

echo "OK: terraform S3+Lambda (${BUCKET} / ${FN})"
