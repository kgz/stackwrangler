#!/usr/bin/env bash
# SNS MaximumMessageSize: default 256 KiB reject; opt-in 1 MiB publish + SQS raw delivery (#373).
# Large-topic subscribe: only firehose/sqs/lambda; http/email/sms/application → InvalidParameter (#387).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_PRESET_EP="${AWSBOX_IAM_ENDPOINT-}"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
[[ -n "$_PRESET_EP" ]] && AWSBOX_IAM_ENDPOINT="$_PRESET_EP"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TOPIC="awsbox-sns-mms-${TS}"
QUEUE="awsbox-sns-mms-q-${TS}"
KEEP="${AWSBOX_SNS_KEEP:-0}"
WAIT="${AWSBOX_FANOUT_WAIT:-8}"
TOPIC_ARN="" QUEUE_URL="" SUB="" EXTRA_SUBS=()
TMP="$(mktemp -d)"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	local s
	for s in "${EXTRA_SUBS[@]+"${EXTRA_SUBS[@]}"}"; do
		aws sns unsubscribe --subscription-arn "$s" >/dev/null 2>&1 || true
	done
	[[ -n "$SUB" ]] && aws sns unsubscribe --subscription-arn "$SUB" >/dev/null 2>&1 || true
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

expect_invalid_subscribe() {
	local proto="$1" endpoint="$2"
	local out
	if out="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol "$proto" \
		--notification-endpoint "$endpoint" 2>&1)"; then
		fail "large topic accepted $proto subscribe"
	fi
	printf '%s' "$out" | grep -qiE 'InvalidParameter' \
		|| fail "large-topic $proto reject missing InvalidParameter: $out"
	ok "large topic rejects $proto subscribe"
}

python3 -c 'open("'"$TMP"'/big300.txt","w").write("x"*(300*1024))'
python3 -c 'open("'"$TMP"'/big1m.txt","w").write("y"*1048576)'

# 1. CreateTopic with MaximumMessageSize; GetTopicAttributes returns it
TOPIC_ARN="$(aws sns create-topic --name "${TOPIC}-create" \
	--attributes MaximumMessageSize=1048576 \
	--query TopicArn --output text)"
GOT="$(aws sns get-topic-attributes --topic-arn "$TOPIC_ARN" \
	--query 'Attributes.MaximumMessageSize' --output text)"
[[ "$GOT" == "1048576" ]] || fail "CreateTopic MaximumMessageSize not returned: '$GOT'"
ok "CreateTopic stores MaximumMessageSize=1048576"
aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null
TOPIC_ARN=""

# 2. Default topic: 300 KiB → InvalidParameter / message too long
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)"
if OUT="$(aws sns publish --topic-arn "$TOPIC_ARN" --message "file://$TMP/big300.txt" 2>&1)"; then
	fail "default topic accepted 300 KiB publish"
fi
printf '%s' "$OUT" | grep -qiE 'InvalidParameter|too long' \
	|| fail "default reject missing InvalidParameter/too long: $OUT"
ok "default topic rejects >256 KiB"

# 3. SetTopicAttributes 1 MiB; 300 KiB–1 MiB publish + SQS raw delivery
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" \
	--attribute-name MaximumMessageSize --attribute-value 1048576
GOT="$(aws sns get-topic-attributes --topic-arn "$TOPIC_ARN" \
	--query 'Attributes.MaximumMessageSize' --output text)"
[[ "$GOT" == "1048576" ]] || fail "SetTopicAttributes MaximumMessageSize not returned: '$GOT'"
ok "SetTopicAttributes MaximumMessageSize=1048576"

# 3b. Large topic: http/email/sms/application subscribe → InvalidParameter (#387)
expect_invalid_subscribe http "http://127.0.0.1:9/sns-hook"
expect_invalid_subscribe https "https://127.0.0.1:9/sns-hook"
expect_invalid_subscribe email "nobody@example.com"
expect_invalid_subscribe email-json "nobody@example.com"
expect_invalid_subscribe sms "+15555550100"
expect_invalid_subscribe application \
	"arn:aws:sns:${REGION}:000000000000:app/GCM/awsbox-mms-app"

# 3c. firehose / lambda still accepted (sqs exercised below)
ACCT="$(printf '%s' "$TOPIC_ARN" | awk -F: '{print $5}')"
LAM_SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol lambda \
	--notification-endpoint "arn:aws:lambda:${REGION}:${ACCT}:function:awsbox-mms-fn-${TS}" \
	--query SubscriptionArn --output text)"
[[ -n "$LAM_SUB" && "$LAM_SUB" != "None" ]] || fail "lambda subscribe on large topic failed"
EXTRA_SUBS+=("$LAM_SUB")
ok "large topic accepts lambda subscribe"
FH_SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol firehose \
	--notification-endpoint "arn:aws:firehose:${REGION}:${ACCT}:deliverystream/awsbox-mms-fh-${TS}" \
	--query SubscriptionArn --output text)"
[[ -n "$FH_SUB" && "$FH_SUB" != "None" ]] || fail "firehose subscribe on large topic failed"
EXTRA_SUBS+=("$FH_SUB")
ok "large topic accepts firehose subscribe"

# 3d. SetTopicAttributes >256 KiB refused when an unsupported subscription exists
HTTP_TOPIC_ARN="$(aws sns create-topic --name "${TOPIC}-http" --query TopicArn --output text)"
HTTP_SUB="$(aws sns subscribe --topic-arn "$HTTP_TOPIC_ARN" --protocol http \
	--notification-endpoint "http://127.0.0.1:9/sns-hook" \
	--query SubscriptionArn --output text)"
if OUT="$(aws sns set-topic-attributes --topic-arn "$HTTP_TOPIC_ARN" \
	--attribute-name MaximumMessageSize --attribute-value 1048576 2>&1)"; then
	aws sns unsubscribe --subscription-arn "$HTTP_SUB" >/dev/null 2>&1 || true
	aws sns delete-topic --topic-arn "$HTTP_TOPIC_ARN" >/dev/null 2>&1 || true
	fail "SetTopicAttributes raised MaximumMessageSize with http subscription"
fi
printf '%s' "$OUT" | grep -qiE 'InvalidParameter' \
	|| fail "SetTopicAttributes with http sub missing InvalidParameter: $OUT"
aws sns unsubscribe --subscription-arn "$HTTP_SUB" >/dev/null 2>&1 || true
aws sns delete-topic --topic-arn "$HTTP_TOPIC_ARN" >/dev/null 2>&1 || true
ok "SetTopicAttributes >256 KiB refused with http subscription"

QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
	--query Attributes.QueueArn --output text)"
POLICY="$(python3 - "$QARN" "$TOPIC_ARN" <<'PY'
import json,sys
qarn,tarn=sys.argv[1:3]
st={"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":qarn,
    "Condition":{"ArnEquals":{"aws:SourceArn":tarn}}}
print(json.dumps({"Policy":json.dumps({"Version":"2012-10-17","Statement":[st]})}))
PY
)"
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes "$POLICY"
SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QARN" \
	--query SubscriptionArn --output text)"
aws sns set-subscription-attributes --subscription-arn "$SUB" \
	--attribute-name RawMessageDelivery --attribute-value true
ok "large topic accepts sqs subscribe"

MID="$(aws sns publish --topic-arn "$TOPIC_ARN" --message "file://$TMP/big300.txt" --query MessageId --output text)"
[[ -n "$MID" && "$MID" != "None" ]] || fail "300 KiB publish failed after MaximumMessageSize"
ok "300 KiB publish succeeded"

end=$((SECONDS + WAIT))
GOT_LEN=0
while ((SECONDS < end)); do
	OUT="$(aws sqs receive-message --queue-url "$QUEUE_URL" --wait-time-seconds 1 --max-number-of-messages 1 --output json)"
	GOT_LEN="$(printf '%s' "$OUT" | python3 -c 'import json,sys
t=sys.stdin.read().strip()
m=(json.loads(t) if t else {}).get("Messages") or []
print(len(m[0]["Body"]) if m else 0)')"
	if ((GOT_LEN > 0)); then
		RH="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Messages"][0]["ReceiptHandle"])')"
		aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$RH" >/dev/null
		break
	fi
done
[[ "$GOT_LEN" == "$((300*1024))" ]] || fail "SQS raw delivery size mismatch (got ${GOT_LEN} bytes)"
ok "SQS subscriber received 300 KiB raw"

MID="$(aws sns publish --topic-arn "$TOPIC_ARN" --message "file://$TMP/big1m.txt" --query MessageId --output text)"
[[ -n "$MID" && "$MID" != "None" ]] || fail "1 MiB publish failed after MaximumMessageSize"
ok "1 MiB publish succeeded"

echo "OK: sns MaximumMessageSize (${TOPIC})"
