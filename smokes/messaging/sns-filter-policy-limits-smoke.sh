#!/usr/bin/env bash
# SNS FilterPolicy limits: empty list, >5 keys, >150 combinations; both scopes (#448).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_PRESET_EP="${AWSBOX_IAM_ENDPOINT-}"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
[[ -n "$_PRESET_EP" ]] && AWSBOX_IAM_ENDPOINT="$_PRESET_EP"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TOPIC="awsbox-sns-fpl-${TS}"
QUEUE="awsbox-sns-fpl-q-${TS}"
KEEP="${AWSBOX_SNS_KEEP:-0}"
WAIT="${AWSBOX_FANOUT_WAIT:-8}"
QUIET="${AWSBOX_FANOUT_QUIET:-4}"
TOPIC_ARN="" QUEUE_URL="" SUB=""
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SUB" ]] && aws sns unsubscribe --subscription-arn "$SUB" >/dev/null 2>&1 || true
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

recv() {
	local url="$1" end=$((SECONDS + $2)) out body
	while ((SECONDS < end)); do
		out="$(aws sqs receive-message --queue-url "$url" --wait-time-seconds 1 --output json)"
		body="$(printf '%s' "$out" | python3 -c 'import json,sys
t=sys.stdin.read().strip()
m=(json.loads(t) if t else {}).get("Messages") or []
print(m[0]["Body"] if m else "",end="")')"
		if [[ -n "$body" ]]; then
			rh="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Messages"][0]["ReceiptHandle"])')"
			aws sqs delete-message --queue-url "$url" --receipt-handle "$rh" >/dev/null
			printf '%s' "$body"
			return 0
		fi
	done
	return 0
}

policy() {
	python3 - "$1" "$2" <<'PY'
import json,sys
qarn,tarn=sys.argv[1:3]
st={"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":qarn,
    "Condition":{"ArnEquals":{"aws:SourceArn":tarn}}}
print(json.dumps({"Policy":json.dumps({"Version":"2012-10-17","Statement":[st]})}))
PY
}

expect_invalid_filter() {
	local scope="$1" label="$2" policy="$3"
	local out
	aws sns set-subscription-attributes --subscription-arn "$SUB" \
		--attribute-name FilterPolicyScope --attribute-value "$scope" >/dev/null
	if out="$(aws sns set-subscription-attributes --subscription-arn "$SUB" \
		--attribute-name FilterPolicy --attribute-value "$policy" 2>&1)"; then
		fail "$scope $label accepted"
	fi
	printf '%s' "$out" | grep -qiE 'InvalidParameter' \
		|| fail "$scope $label reject missing InvalidParameter: $out"
	ok "$scope rejects $label"
}

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)"
QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
QUEUE_ARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
	--query Attributes.QueueArn --output text)"
[[ -n "$TOPIC_ARN" && -n "$QUEUE_ARN" ]] || fail "setup"
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "$(policy "$QUEUE_ARN" "$TOPIC_ARN")"
SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QUEUE_ARN" \
	--attributes RawMessageDelivery=true --query SubscriptionArn --output text)"
[[ "$SUB" == arn:aws:sns:* ]] || fail "subscribe returned '$SUB'"
ok "topic, queue, subscription ready"

SIX_KEYS='{"a":["1"],"b":["1"],"c":["1"],"d":["1"],"e":["1"],"f":["1"]}'
COMPLEX151="$(python3 -c 'import json; print(json.dumps({"color":[str(i) for i in range(151)]}))')"
HAPPY150="$(python3 -c 'import json; print(json.dumps({"color":[str(i) for i in range(150)]}))')"

for scope in MessageAttributes MessageBody; do
	expect_invalid_filter "$scope" "empty array" '{"color":[]}'
	expect_invalid_filter "$scope" ">5 keys" "$SIX_KEYS"
	expect_invalid_filter "$scope" ">150 combinations" "$COMPLEX151"
done

# Happy: 150-value MessageAttributes policy filters correctly
aws sns set-subscription-attributes --subscription-arn "$SUB" \
	--attribute-name FilterPolicyScope --attribute-value MessageAttributes >/dev/null
aws sns set-subscription-attributes --subscription-arn "$SUB" \
	--attribute-name FilterPolicy --attribute-value "$HAPPY150"
ok "MessageAttributes accepts 150-value FilterPolicy"

aws sns publish --topic-arn "$TOPIC_ARN" --message "drop-ma-${TS}" \
	--message-attributes '{"color":{"DataType":"String","StringValue":"nomatch"}}' >/dev/null
aws sns publish --topic-arn "$TOPIC_ARN" --message "keep-ma-${TS}" \
	--message-attributes '{"color":{"DataType":"String","StringValue":"42"}}' >/dev/null
B="$(recv "$QUEUE_URL" "$WAIT")"
[[ "$B" == "keep-ma-${TS}" ]] || fail "MA filter: first delivered was '$B' (expected keep-ma-${TS})"
B="$(recv "$QUEUE_URL" "$QUIET")"
[[ -z "$B" ]] || fail "MA filter: non-matching message delivered: '$B'"
ok "MessageAttributes 150-value policy filters correctly"

# Happy: same policy under MessageBody
aws sns set-subscription-attributes --subscription-arn "$SUB" \
	--attribute-name FilterPolicyScope --attribute-value MessageBody >/dev/null
aws sns set-subscription-attributes --subscription-arn "$SUB" \
	--attribute-name FilterPolicy --attribute-value "$HAPPY150"
ok "MessageBody accepts 150-value FilterPolicy"

aws sns publish --topic-arn "$TOPIC_ARN" --message "{\"color\":\"nomatch\",\"m\":\"drop-mb-${TS}\"}" >/dev/null
aws sns publish --topic-arn "$TOPIC_ARN" --message "{\"color\":\"42\",\"m\":\"keep-mb-${TS}\"}" >/dev/null
B="$(recv "$QUEUE_URL" "$WAIT")"
[[ "$B" == "{\"color\":\"42\",\"m\":\"keep-mb-${TS}\"}" ]] \
	|| fail "MB filter: first delivered was '$B'"
B="$(recv "$QUEUE_URL" "$QUIET")"
[[ -z "$B" ]] || fail "MB filter: non-matching message delivered: '$B'"
ok "MessageBody 150-value policy filters correctly"

ok "sns-filter-policy-limits-smoke passed"
