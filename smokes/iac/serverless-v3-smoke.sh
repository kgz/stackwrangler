#!/usr/bin/env bash
# Deploy examples/serverless-v3-rest with Serverless Framework v3 against LocalEmu:
# deploy → hit /public/health → redeploy → remove.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v3-rest"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
STAGE="local"
# Always unique unless the caller opts into a fixed name (tests).
DEPLOY_BUCKET="awsbox-sls-deploy-${TS}"
[[ -n "${AWSBOX_SLSE_DEPLOY_BUCKET_OVERRIDE:-}" ]] && DEPLOY_BUCKET="$AWSBOX_SLSE_DEPLOY_BUCKET_OVERRIDE"
SUFFIX="${TS}"
SERVICE="awsbox-rest-${TS}"
[[ -n "${AWSBOX_SLSE_SERVICE_OVERRIDE:-}" ]] && SERVICE="$AWSBOX_SLSE_SERVICE_OVERRIDE"
STACK="${SERVICE}-${STAGE}"
KEEP="${AWSBOX_SLS_V3_KEEP:-0}"
OUT="$ROOT/.awsbox/serverless-v3-${TS}"
REMOVED=0
# serverless + localstack plugin often leaves the node process open after success.
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-120}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
# Force every SDK call (incl. S3 artifacts) onto LocalEmu — not SeaweedFS via profile local.
export AWS_ENDPOINT_URL="$EP"
export AWSBOX_SLSE_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLSE_SUFFIX="$SUFFIX"
export AWSBOX_SLSE_SERVICE="$SERVICE"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

# Run serverless; succeed if the log shows the expected marker even when the CLI hangs.
sls_run() {
	local marker="$1"
	local log="$2"
	shift 2
	set +e
	(
		cd "$EX"
		# stdbuf: line-buffer so timeout sees "Service deployed" promptly.
		timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
			stdbuf -oL -eL \
			npx serverless "$@" --stage "$STAGE"
	) >"$log" 2>&1
	local rc=$?
	set -e
	if grep -qiE "$marker" "$log"; then
		# Strip spinner ANSI so the printed log is readable.
		sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | grep -v '^[[:space:]]*$' || cat "$log"
		return 0
	fi
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' >&2 || cat "$log" >&2 || true
	echo "error: serverless did not report '${marker}' (exit ${rc}, timeout ${SLS_TIMEOUT_SECS}s)" >&2
	return 1
}

cleanup() {
	if [[ "$KEEP" == "1" ]]; then
		return 0
	fi
	if [[ "$REMOVED" != "1" ]]; then
		(
			cd "$EX"
			timeout --signal=KILL 90 stdbuf -oL -eL \
				npx serverless remove --stage "$STAGE" --verbose
		) >"$OUT/remove-cleanup.log" 2>&1 || true
	fi
	aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
	aws ssm delete-parameter --name "/demo/rest/${SUFFIX}/app-name" >/dev/null 2>&1 || true
	[[ "$KEEP" == "1" ]] || rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/awsbox up)" >&2
	exit 1
fi

if [[ ! -d "$EX/node_modules/serverless" ]]; then
	(cd "$EX" && npm install --no-fund --no-audit)
fi

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
aws ssm put-parameter \
	--name "/demo/rest/${SUFFIX}/app-name" \
	--type String \
	--value "awsbox-rest-smoke" \
	--overwrite >/dev/null

echo "==> serverless deploy (1)"
sls_run 'Service deployed' "$OUT/deploy1.log" deploy --verbose

API_ID="$(aws cloudformation describe-stack-resources --stack-name "$STACK" \
	--query "StackResources[?LogicalResourceId=='ApiGatewayRestApi'].PhysicalResourceId" \
	--output text 2>/dev/null || true)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
	API_ID="$(aws apigateway get-rest-apis --query "items[?name=='${STAGE}-${SERVICE}'].id | [0]" --output text 2>/dev/null || true)"
fi
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
	API_ID="$(aws apigateway get-rest-apis --query "items[?contains(name, '${SERVICE}')].id | [0]" --output text)"
fi
[[ -n "$API_ID" && "$API_ID" != "None" ]] || {
	echo "error: could not resolve RestApi id for stack ${STACK}" >&2
	aws cloudformation describe-stack-resources --stack-name "$STACK" --output table >&2 || true
	exit 1
}

BASE="${EP}/restapis/${API_ID}/${STAGE}/_user_request_"
echo "==> invoke ${BASE}/public/health"
code="$(curl -s -o "$OUT/health.json" -w '%{http_code}' "${BASE}/public/health")"
echo "http ${code}"
cat "$OUT/health.json"
echo
[[ "$code" == "200" ]] || {
	echo "error: expected 200 from /public/health, got ${code}" >&2
	exit 1
}
grep -q '"ok": *true\|"ok":true' "$OUT/health.json"
grep -q 'awsbox-rest-smoke' "$OUT/health.json"

OPENAPI_ID="$(aws cloudformation describe-stack-resources --stack-name "$STACK" \
	--query "StackResources[?LogicalResourceId=='OpenApiRestApi'].PhysicalResourceId" \
	--output text 2>/dev/null || true)"
[[ -n "$OPENAPI_ID" && "$OPENAPI_ID" != "None" ]] || {
	echo "error: OpenApiRestApi Body resource missing from stack ${STACK}" >&2
	aws cloudformation describe-stack-resources --stack-name "$STACK" --output table >&2 || true
	exit 1
}
echo "ok   OpenApiRestApi Body resource: ${OPENAPI_ID}"

VPCLINK_ID="$(aws cloudformation describe-stack-resources --stack-name "$STACK" \
	--query "StackResources[?LogicalResourceId=='StubVpcLink'].PhysicalResourceId" \
	--output text 2>/dev/null || true)"
[[ -n "$VPCLINK_ID" && "$VPCLINK_ID" != "None" ]] || {
	echo "error: StubVpcLink missing from stack ${STACK} (VPC Link→NLB→ECS shape)" >&2
	exit 1
}
echo "ok   StubVpcLink: ${VPCLINK_ID}"

echo "==> serverless deploy (2 / redeploy)"
# Change provider env so CFN must update (not a no-op / "No changes to deploy").
export AWSBOX_SLSE_REDEPLOY_MARK="redeploy-${TS}"
sls_run 'Updating CloudFormation stack|UPDATE_IN_PROGRESS|UPDATE_COMPLETE' \
	"$OUT/deploy2.log" deploy --verbose --force
if grep -qiE 'No changes to deploy' "$OUT/deploy2.log"; then
	echo "error: redeploy was a no-op (No changes to deploy)" >&2
	exit 1
fi
grep -qiE 'Updating CloudFormation stack|UPDATE_IN_PROGRESS' "$OUT/deploy2.log" || {
	echo "error: redeploy did not update CloudFormation (no UPDATE_* / Updating evidence)" >&2
	exit 1
}

code="$(curl -s -o "$OUT/health2.json" -w '%{http_code}' "${BASE}/public/health")"
[[ "$code" == "200" ]] || {
	echo "error: post-redeploy health got ${code}" >&2
	exit 1
}
grep -q "redeploy-${TS}" "$OUT/health2.json" || {
	echo "error: post-redeploy body missing REDEPLOY_MARK=redeploy-${TS}" >&2
	cat "$OUT/health2.json" >&2
	exit 1
}

echo "==> serverless remove"
sls_run 'Service removed|Removing service|Stack removal finished|Successfully removed|removing' \
	"$OUT/remove.log" remove --verbose
REMOVED=1

if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
	st="$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text)"
	[[ "$st" == "DELETE_COMPLETE" ]] || {
		echo "error: stack ${STACK} still ${st} after remove" >&2
		exit 1
	}
fi

echo "OK: serverless v3 deploy/invoke/redeploy/remove (${STACK} / api ${API_ID})"
