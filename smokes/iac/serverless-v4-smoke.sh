#!/usr/bin/env bash
# Deploy examples/serverless-v4-sns-sqs (topic + consumer) against LocalEmu:
# deploy both → SNS publish → Lambda S3 marker → redeploy consumer → remove.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v4-sns-sqs"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-awsbox}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-awsboxawsbox}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
STAGE="local"
DEPLOY_BUCKET="awsbox-sls4-deploy-${TS}"
[[ -n "${AWSBOX_SLS4_DEPLOY_BUCKET_OVERRIDE:-}" ]] && DEPLOY_BUCKET="$AWSBOX_SLS4_DEPLOY_BUCKET_OVERRIDE"
SUFFIX="${TS}"
TOPIC_SERVICE="awsbox-sls4-topic-${TS}"
CONSUMER_SERVICE="awsbox-sls4-consumer-${TS}"
[[ -n "${AWSBOX_SLS4_TOPIC_SERVICE_OVERRIDE:-}" ]] && TOPIC_SERVICE="$AWSBOX_SLS4_TOPIC_SERVICE_OVERRIDE"
[[ -n "${AWSBOX_SLS4_CONSUMER_SERVICE_OVERRIDE:-}" ]] && CONSUMER_SERVICE="$AWSBOX_SLS4_CONSUMER_SERVICE_OVERRIDE"
TOPIC_STACK="${TOPIC_SERVICE}-${STAGE}"
CONSUMER_STACK="${CONSUMER_SERVICE}-${STAGE}"
TOPIC_EXPORT="${TOPIC_SERVICE}-${STAGE}-TopicArn"
KEEP="${AWSBOX_SLS_V4_KEEP:-0}"
OUT="$ROOT/.awsbox/serverless-v4-${TS}"
REMOVED=0
TOPIC_DEPLOYED=0
CONSUMER_DEPLOYED=0
BUCKET_CREATED=0
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-180}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
# Force every SDK call (incl. S3 artifacts) onto LocalEmu — not SeaweedFS via profile local.
export AWS_ENDPOINT_URL="$EP"
# Helps virtual-hosted S3 clients that ignore path-style (resolves to 127.0.0.1 here).
export AWS_ENDPOINT_URL_S3="${AWSBOX_SLS4_S3_ENDPOINT:-http://s3.localhost.localstack.cloud:4566}"
export AWSBOX_SLS4_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLS4_SUFFIX="$SUFFIX"
export AWSBOX_SLS4_TOPIC_SERVICE="$TOPIC_SERVICE"
export AWSBOX_SLS4_CONSUMER_SERVICE="$CONSUMER_SERVICE"
export AWSBOX_SLS4_TOPIC_EXPORT="$TOPIC_EXPORT"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

require_sls_auth() {
	if [[ -n "${SERVERLESS_LICENSE_KEY:-}" || -n "${SERVERLESS_ACCESS_KEY:-}" ]]; then
		return 0
	fi
	echo "error: Serverless Framework v4 needs auth for every command (incl. package)." >&2
	echo "  Free / under-\$2M: export SERVERLESS_ACCESS_KEY=… (Dashboard → Settings → Access Keys)" >&2
	echo "  Paid subscription: export SERVERLESS_LICENSE_KEY=…" >&2
	echo "  Neither is offline — the CLI validates against Serverless Inc." >&2
	echo "  See docs/serverless-awsbox.md" >&2
	exit 1
}

# Run serverless in a service dir; succeed if the log shows the expected marker even when the CLI hangs.
sls_run() {
	local dir="$1"
	local marker="$2"
	local log="$3"
	shift 3
	set +e
	(
		cd "$dir"
		timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
			stdbuf -oL -eL \
			npx serverless "$@" --stage "$STAGE"
	) >"$log" 2>&1
	local rc=$?
	set -e
	if grep -qiE "$marker" "$log"; then
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
		if [[ "$CONSUMER_DEPLOYED" == "1" ]]; then
			(
				cd "$EX/consumer"
				timeout --signal=KILL 90 stdbuf -oL -eL \
					npx serverless remove --stage "$STAGE" --verbose
			) >"$OUT/remove-consumer-cleanup.log" 2>&1 || true
		fi
		if [[ "$TOPIC_DEPLOYED" == "1" ]]; then
			(
				cd "$EX/topic"
				timeout --signal=KILL 90 stdbuf -oL -eL \
					npx serverless remove --stage "$STAGE" --verbose
			) >"$OUT/remove-topic-cleanup.log" 2>&1 || true
		fi
	fi
	if [[ "$BUCKET_CREATED" == "1" ]]; then
		aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/app-name" >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/topic-arn" >/dev/null 2>&1 || true
	fi
	[[ -d "$OUT" ]] && rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"
require_sls_auth

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/awsbox up)" >&2
	exit 1
fi

if [[ ! -d "$EX/node_modules/serverless" ]]; then
	(cd "$EX" && npm install --no-fund --no-audit)
fi

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
BUCKET_CREATED=1
aws ssm put-parameter \
	--name "/demo/sls4/${SUFFIX}/app-name" \
	--type String \
	--value "awsbox-sls4-smoke" \
	--overwrite >/dev/null

echo "==> serverless deploy topic"
sls_run "$EX/topic" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-topic.log" deploy --verbose
TOPIC_DEPLOYED=1

TOPIC_ARN="$(aws cloudformation describe-stacks --stack-name "$TOPIC_STACK" \
	--query "Stacks[0].Outputs[?OutputKey=='TopicArn'].OutputValue | [0]" \
	--output text 2>/dev/null || true)"
if [[ -z "$TOPIC_ARN" || "$TOPIC_ARN" == "None" ]]; then
	TOPIC_ARN="$(aws ssm get-parameter --name "/demo/sls4/${SUFFIX}/topic-arn" \
		--query 'Parameter.Value' --output text)"
fi
[[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != "None" ]] || {
	echo "error: could not resolve TopicArn after topic deploy" >&2
	aws cloudformation describe-stacks --stack-name "$TOPIC_STACK" --output table >&2 || true
	exit 1
}
echo "ok   TopicArn=${TOPIC_ARN}"

echo "==> serverless deploy consumer"
sls_run "$EX/consumer" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-consumer.log" deploy --verbose
CONSUMER_DEPLOYED=1

RESULTS_BUCKET="${CONSUMER_SERVICE}-${STAGE}-results-${SUFFIX}"
aws s3api head-bucket --bucket "$RESULTS_BUCKET" >/dev/null 2>&1 || {
	echo "error: results bucket ${RESULTS_BUCKET} missing after consumer deploy" >&2
	aws cloudformation describe-stack-resources --stack-name "$CONSUMER_STACK" --output table >&2 || true
	exit 1
}

MSG="keep-${TS}"
echo "==> sns publish (filter keep)"
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$MSG" \
	--message-attributes "kind={DataType=String,StringValue=keep}" >/dev/null

# Drop should not land (filter). Ignore failure to deliver.
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "drop-${TS}" \
	--message-attributes "kind={DataType=String,StringValue=drop}" >/dev/null || true

echo "==> wait for Lambda → S3 marker"
found=""
for _ in $(seq 1 40); do
	if aws s3 ls "s3://${RESULTS_BUCKET}/got/" 2>/dev/null | grep -q .; then
		found=1
		break
	fi
	sleep 2
done
[[ -n "$found" ]] || {
	echo "error: no objects under s3://${RESULTS_BUCKET}/got/ after SNS publish" >&2
	aws s3 ls "s3://${RESULTS_BUCKET}/" --recursive >&2 || true
	aws lambda list-event-source-mappings --output table >&2 || true
	exit 1
}
aws s3 cp "s3://${RESULTS_BUCKET}/got/" "$OUT/got/" --recursive >/dev/null
grep -q "$MSG" "$OUT/got/"* || {
	echo "error: S3 marker missing body ${MSG}" >&2
	cat "$OUT/got/"* >&2
	exit 1
}
grep -q 'awsbox-sls4-smoke' "$OUT/got/"* || {
	echo "error: S3 marker missing APP_NAME from \${ssm:…}" >&2
	cat "$OUT/got/"* >&2
	exit 1
}
echo "ok   Lambda wrote S3 marker for ${MSG}"

echo "==> serverless deploy consumer (2 / redeploy)"
export AWSBOX_SLS4_REDEPLOY_MARK="redeploy-${TS}"
sls_run "$EX/consumer" 'Updating CloudFormation stack|UPDATE_IN_PROGRESS|UPDATE_COMPLETE|Service deployed' \
	"$OUT/deploy-consumer2.log" deploy --verbose --force
if grep -qiE 'No changes to deploy' "$OUT/deploy-consumer2.log"; then
	echo "error: consumer redeploy was a no-op (No changes to deploy)" >&2
	exit 1
fi

MSG2="keep-redeploy-${TS}"
aws s3 rm "s3://${RESULTS_BUCKET}/got/" --recursive >/dev/null 2>&1 || true
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$MSG2" \
	--message-attributes "kind={DataType=String,StringValue=keep}" >/dev/null
found=""
for _ in $(seq 1 40); do
	if aws s3 ls "s3://${RESULTS_BUCKET}/got/" 2>/dev/null | grep -q .; then
		found=1
		break
	fi
	sleep 2
done
[[ -n "$found" ]] || {
	echo "error: no S3 objects after redeploy publish" >&2
	exit 1
}
aws s3 cp "s3://${RESULTS_BUCKET}/got/" "$OUT/got2/" --recursive >/dev/null
grep -q "redeploy-${TS}" "$OUT/got2/"* || {
	echo "error: post-redeploy body missing REDEPLOY_MARK=redeploy-${TS}" >&2
	cat "$OUT/got2/"* >&2
	exit 1
}

echo "==> serverless remove (consumer then topic)"
sls_run "$EX/consumer" 'Service removed|Removing service|Stack removal finished|Successfully removed|removing' \
	"$OUT/remove-consumer.log" remove --verbose
sls_run "$EX/topic" 'Service removed|Removing service|Stack removal finished|Successfully removed|removing' \
	"$OUT/remove-topic.log" remove --verbose
REMOVED=1

for stack in "$CONSUMER_STACK" "$TOPIC_STACK"; do
	if aws cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
		st="$(aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text)"
		[[ "$st" == "DELETE_COMPLETE" ]] || {
			echo "error: stack ${stack} still ${st} after remove" >&2
			exit 1
		}
	fi
done

echo "OK: serverless v4 topic+consumer deploy/publish/redeploy/remove (${TOPIC_STACK} → ${CONSUMER_STACK})"
