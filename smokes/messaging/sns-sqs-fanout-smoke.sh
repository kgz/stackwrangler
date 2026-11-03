#!/usr/bin/env bash
# SNS -> SQS fan-out: envelope, raw delivery, filter policy, queue-policy authz (sad),
# alias/aws/sqs KMS refuse (sad), CMK without SNS key grant (sad), CMK with SNS grant
# (happy), unsubscribe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Caller-exported AWSBOX_* wins over .env (parallel worktrees / alt ports).
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
TOPIC="awsbox-fanout-${TS}"
QOK="awsbox-fanout-ok-${TS}"
QDENY="awsbox-fanout-deny-${TS}"
QNOPOL="awsbox-fanout-nopol-${TS}"
QAWSSQS="awsbox-fanout-awssqs-${TS}"
QCMK="awsbox-fanout-cmk-${TS}"
QCMKOK="awsbox-fanout-cmkok-${TS}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
WAIT="${AWSBOX_FANOUT_WAIT:-8}"   # seconds to wait for a delivery
QUIET="${AWSBOX_FANOUT_QUIET:-4}" # seconds to wait before declaring "not delivered"
TOPIC_ARN="" QOK_URL="" QDENY_URL="" QNOPOL_URL="" QAWSSQS_URL="" QCMK_URL="" QCMKOK_URL=""
KEY_NOSNS="" KEY_SNS="" SUBS=()
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	for s in "${SUBS[@]:-}"; do [[ -n "$s" ]] && aws sns unsubscribe --subscription-arn "$s" >/dev/null 2>&1 || true; done
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$QOK_URL" ]] && aws sqs delete-queue --queue-url "$QOK_URL" >/dev/null 2>&1 || true
	[[ -n "$QDENY_URL" ]] && aws sqs delete-queue --queue-url "$QDENY_URL" >/dev/null 2>&1 || true
	[[ -n "$QNOPOL_URL" ]] && aws sqs delete-queue --queue-url "$QNOPOL_URL" >/dev/null 2>&1 || true
	[[ -n "$QAWSSQS_URL" ]] && aws sqs delete-queue --queue-url "$QAWSSQS_URL" >/dev/null 2>&1 || true
	[[ -n "$QCMK_URL" ]] && aws sqs delete-queue --queue-url "$QCMK_URL" >/dev/null 2>&1 || true
	[[ -n "$QCMKOK_URL" ]] && aws sqs delete-queue --queue-url "$QCMKOK_URL" >/dev/null 2>&1 || true
	[[ -n "$KEY_NOSNS" ]] && aws kms schedule-key-deletion --key-id "$KEY_NOSNS" --pending-window-in-days 7 >/dev/null 2>&1 || true
	[[ -n "$KEY_SNS" ]] && aws kms schedule-key-deletion --key-id "$KEY_SNS" --pending-window-in-days 7 >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# recv URL SECONDS -> prints first message body (empty if none within SECONDS), deletes it
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
jget() { python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"; }
policy() { # queue-arn topic-arn-or-"" -> queue Policy attribute JSON (attributes map)
	python3 - "$1" "$2" <<'PY'
import json,sys
qarn,tarn=sys.argv[1:3]
# allow only the given source ARN; an unrelated ARN when tarn is "deny"
st={"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":qarn,
    "Condition":{"ArnEquals":{"aws:SourceArn":tarn}}}
print(json.dumps({"Policy":json.dumps({"Version":"2012-10-17","Statement":[st]})}))
PY
}
# mode (nosns|sns) account-id -> KMS key policy JSON
key_policy() {
	python3 - "$1" "$2" <<'PY'
import json, sys
mode, acct = sys.argv[1], sys.argv[2]
root = f"arn:aws:iam::{acct}:root"
stmts = [{
    "Sid": "Enable IAM User Permissions",
    "Effect": "Allow",
    "Principal": {"AWS": root},
    "Action": "kms:*",
    "Resource": "*",
}]
if mode == "sns":
    stmts.append({
        "Sid": "AllowSns",
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": ["kms:GenerateDataKey*", "kms:Decrypt"],
        "Resource": "*",
    })
print(json.dumps({"Version": "2012-10-17", "Statement": stmts}))
PY
}

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)"
QOK_URL="$(aws sqs create-queue --queue-name "$QOK" --query QueueUrl --output text)"
QDENY_URL="$(aws sqs create-queue --queue-name "$QDENY" --query QueueUrl --output text)"
QOK_ARN="$(aws sqs get-queue-attributes --queue-url "$QOK_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
QDENY_ARN="$(aws sqs get-queue-attributes --queue-url "$QDENY_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
[[ -n "$TOPIC_ARN" && -n "$QOK_ARN" && -n "$QDENY_ARN" ]] || fail "setup"
ok "topic and queues created"

aws sqs set-queue-attributes --queue-url "$QOK_URL" --attributes "$(policy "$QOK_ARN" "$TOPIC_ARN")"
SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QOK_ARN" --query SubscriptionArn --output text)"
SUBS+=("$SUB")
[[ "$SUB" == arn:aws:sns:* ]] || fail "subscribe returned '$SUB'"
ok "subscribed (queue policy allows sns:SendMessage from topic)"

# 1. envelope
aws sns publish --topic-arn "$TOPIC_ARN" --message "hello-${TS}" --subject subj >/dev/null
B="$(recv "$QOK_URL" "$WAIT")"
[[ -n "$B" ]] || fail "envelope: nothing delivered"
[[ "$(jget "$B" Type)" == "Notification" && "$(jget "$B" Message)" == "hello-${TS}" && "$(jget "$B" TopicArn)" == "$TOPIC_ARN" ]] \
	|| fail "envelope wrong: $B"
ok "message arrived with SNS envelope"

# 2. raw delivery
aws sns set-subscription-attributes --subscription-arn "$SUB" --attribute-name RawMessageDelivery --attribute-value true
aws sns publish --topic-arn "$TOPIC_ARN" --message "raw-${TS}" >/dev/null
B="$(recv "$QOK_URL" "$WAIT")"
[[ "$B" == "raw-${TS}" ]] || fail "raw delivery: got '$B'"
ok "RawMessageDelivery=true delivers bare body"

# 3. filter policy
aws sns set-subscription-attributes --subscription-arn "$SUB" --attribute-name FilterPolicy --attribute-value '{"kind":["keep"]}'
aws sns publish --topic-arn "$TOPIC_ARN" --message "drop-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"other"}}' >/dev/null
aws sns publish --topic-arn "$TOPIC_ARN" --message "keep-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QOK_URL" "$WAIT")"
[[ "$B" == "keep-${TS}" ]] || fail "filter: first delivered was '$B' (expected keep-${TS})"
B="$(recv "$QOK_URL" "$QUIET")"
[[ -z "$B" ]] || fail "filter: non-matching message delivered: '$B'"
ok "filter policy dropped non-matching message"

# 4. sad: queue policy does not allow this topic
aws sqs set-queue-attributes --queue-url "$QDENY_URL" \
	--attributes "$(policy "$QDENY_ARN" "arn:aws:sns:${REGION}:000000000000:some-other-topic-${TS}")"
DSUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QDENY_ARN" --query SubscriptionArn --output text)"
SUBS+=("$DSUB")
aws sns publish --topic-arn "$TOPIC_ARN" --message "nope-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QDENY_URL" "$QUIET")"
[[ -z "$B" ]] || fail "authz: delivered despite queue policy not allowing topic: '$B'"
ok "queue policy not allowing the topic: message NOT delivered"
# drain the keep message the allowed sub got
recv "$QOK_URL" "$WAIT" >/dev/null

# 5. sad: queue with no policy receives nothing (Subscribe still succeeds)
QNOPOL_URL="$(aws sqs create-queue --queue-name "$QNOPOL" --query QueueUrl --output text)"
QNOPOL_ARN="$(aws sqs get-queue-attributes --queue-url "$QNOPOL_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
NSUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QNOPOL_ARN" --query SubscriptionArn --output text)"
SUBS+=("$NSUB")
[[ "$NSUB" == arn:aws:sns:* ]] || fail "nopol subscribe returned '$NSUB'"
aws sns publish --topic-arn "$TOPIC_ARN" --message "nopol-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QNOPOL_URL" "$QUIET")"
[[ -z "$B" ]] || fail "authz: delivered to queue with no policy: '$B'"
ok "queue with no policy: message NOT delivered"
recv "$QOK_URL" "$WAIT" >/dev/null

# 6. sad: queue encrypted with alias/aws/sqs — AWS cannot grant SNS on that key
QAWSSQS_URL="$(aws sqs create-queue --queue-name "$QAWSSQS" \
	--attributes KmsMasterKeyId=alias/aws/sqs --query QueueUrl --output text)"
QAWSSQS_ARN="$(aws sqs get-queue-attributes --queue-url "$QAWSSQS_URL" \
	--attribute-names QueueArn --query Attributes.QueueArn --output text)"
KMS_ATTR="$(aws sqs get-queue-attributes --queue-url "$QAWSSQS_URL" \
	--attribute-names KmsMasterKeyId --query Attributes.KmsMasterKeyId --output text)"
[[ "$KMS_ATTR" == *aws/sqs* ]] || fail "expected KmsMasterKeyId alias/aws/sqs, got '$KMS_ATTR'"
aws sqs set-queue-attributes --queue-url "$QAWSSQS_URL" --attributes "$(policy "$QAWSSQS_ARN" "$TOPIC_ARN")"
KSUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QAWSSQS_ARN" \
	--attributes RawMessageDelivery=true --query SubscriptionArn --output text)"
SUBS+=("$KSUB")
[[ "$KSUB" == arn:aws:sns:* ]] || fail "alias/aws/sqs subscribe returned '$KSUB'"
aws sns publish --topic-arn "$TOPIC_ARN" --message "awssqs-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QAWSSQS_URL" "$QUIET")"
[[ -z "$B" ]] || fail "alias/aws/sqs: SNS delivered despite AWS-managed SQS key: '$B'"
ok "queue with KmsMasterKeyId=alias/aws/sqs: message NOT delivered"
recv "$QOK_URL" "$WAIT" >/dev/null

# 7. sad: customer CMK whose key policy does not grant sns.amazonaws.com
ACCT="${TOPIC_ARN#arn:aws:sns:${REGION}:}"
ACCT="${ACCT%%:*}"
KEY_NOSNS="$(aws kms create-key --description "awsbox-fanout-nosns-${TS}" --query KeyMetadata.KeyId --output text)"
aws kms put-key-policy --key-id "$KEY_NOSNS" --policy-name default --policy "$(key_policy nosns "$ACCT")"
QCMK_URL="$(aws sqs create-queue --queue-name "$QCMK" \
	--attributes "KmsMasterKeyId=${KEY_NOSNS}" --query QueueUrl --output text)"
QCMK_ARN="$(aws sqs get-queue-attributes --queue-url "$QCMK_URL" \
	--attribute-names QueueArn --query Attributes.QueueArn --output text)"
KMS_ATTR="$(aws sqs get-queue-attributes --queue-url "$QCMK_URL" \
	--attribute-names KmsMasterKeyId --query Attributes.KmsMasterKeyId --output text)"
[[ "$KMS_ATTR" == *"$KEY_NOSNS"* ]] || fail "expected KmsMasterKeyId ${KEY_NOSNS}, got '$KMS_ATTR'"
aws sqs set-queue-attributes --queue-url "$QCMK_URL" --attributes "$(policy "$QCMK_ARN" "$TOPIC_ARN")"
CMKSUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QCMK_ARN" \
	--attributes RawMessageDelivery=true --query SubscriptionArn --output text)"
SUBS+=("$CMKSUB")
[[ "$CMKSUB" == arn:aws:sns:* ]] || fail "cmk subscribe returned '$CMKSUB'"
aws sns publish --topic-arn "$TOPIC_ARN" --message "cmk-nosns-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QCMK_URL" "$QUIET")"
[[ -z "$B" ]] || fail "cmk without SNS grant: delivered '$B'"
ok "CMK without sns.amazonaws.com key grant: message NOT delivered"
recv "$QOK_URL" "$WAIT" >/dev/null

# 8. happy: same shape of CMK, key policy Allows SNS GenerateDataKey* + Decrypt
KEY_SNS="$(aws kms create-key --description "awsbox-fanout-sns-${TS}" --query KeyMetadata.KeyId --output text)"
aws kms put-key-policy --key-id "$KEY_SNS" --policy-name default --policy "$(key_policy sns "$ACCT")"
QCMKOK_URL="$(aws sqs create-queue --queue-name "$QCMKOK" \
	--attributes "KmsMasterKeyId=${KEY_SNS}" --query QueueUrl --output text)"
QCMKOK_ARN="$(aws sqs get-queue-attributes --queue-url "$QCMKOK_URL" \
	--attribute-names QueueArn --query Attributes.QueueArn --output text)"
aws sqs set-queue-attributes --queue-url "$QCMKOK_URL" --attributes "$(policy "$QCMKOK_ARN" "$TOPIC_ARN")"
CMKOKSUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs --notification-endpoint "$QCMKOK_ARN" \
	--attributes RawMessageDelivery=true --query SubscriptionArn --output text)"
SUBS+=("$CMKOKSUB")
[[ "$CMKOKSUB" == arn:aws:sns:* ]] || fail "cmk-ok subscribe returned '$CMKOKSUB'"
aws sns publish --topic-arn "$TOPIC_ARN" --message "cmk-sns-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QCMKOK_URL" "$WAIT")"
[[ "$B" == "cmk-sns-${TS}" ]] || fail "cmk with SNS grant: got '$B'"
ok "CMK allowing sns.amazonaws.com: message delivered"
recv "$QOK_URL" "$WAIT" >/dev/null

# 9. unsubscribe stops delivery
aws sns unsubscribe --subscription-arn "$SUB"
aws sns unsubscribe --subscription-arn "$CMKOKSUB" >/dev/null 2>&1 || true
SUBS=("$DSUB" "$NSUB" "$KSUB" "$CMKSUB" "$CMKOKSUB")
aws sns publish --topic-arn "$TOPIC_ARN" --message "after-${TS}" \
	--message-attributes '{"kind":{"DataType":"String","StringValue":"keep"}}' >/dev/null
B="$(recv "$QOK_URL" "$QUIET")"
[[ -z "$B" ]] || fail "unsubscribe: still delivered '$B'"
ok "unsubscribe stops delivery"
echo "OK: sns->sqs fan-out (${TOPIC})"
