#!/usr/bin/env bash
# SNS MaximumMessageSize: default 256 KiB reject; opt-in 1 MiB publish + SQS raw delivery (#373).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_PRESET_EP="${AWSBOX_IAM_ENDPOINT-}"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
[[ -n "$_PRESET_EP" ]] && AWSBOX_IAM_ENDPOINT="$_PRESET_EP"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TOPIC="awsbox-sns-mms-${TS}"
QUEUE="awsbox-sns-mms-q-${TS}"
KEEP="${AWSBOX_SNS_KEEP:-0}"
WAIT="${AWSBOX_FANOUT_WAIT:-8}"
TOPIC_ARN="" QUEUE_URL="" SUB=""
TMP="$(mktemp -d)"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SUB" ]] && aws sns unsubscribe --subscription-arn "$SUB" >/dev/null 2>&1 || true
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

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
