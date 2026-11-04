#!/usr/bin/env bash
# SQS → Lambda ReportBatchItemFailures (#445):
# - batch of 3, function reports 1 failure → 2 deleted, 1 redelivered → DLQ after maxReceiveCount
# - empty batchItemFailures → delete whole batch
# - invalid/unknown itemIdentifier → whole batch fails (all redelivered → DLQ)
# - without FunctionResponseTypes ReportBatchItemFailures → response body ignored (all deleted)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="awsbox-bif-${TS}"
BUCKET="${P}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

UUIDS=()
FNS=()
QURLS=()
ROLES=()
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	for u in "${UUIDS[@]:-}"; do [[ -n "$u" ]] && aws lambda delete-event-source-mapping --uuid "$u" >/dev/null 2>&1 || true; done
	for f in "${FNS[@]:-}"; do [[ -n "$f" ]] && aws lambda delete-function --function-name "$f" >/dev/null 2>&1 || true; done
	for q in "${QURLS[@]:-}"; do [[ -n "$q" ]] && aws sqs delete-queue --queue-url "$q" >/dev/null 2>&1 || true; done
	for r in "${ROLES[@]:-}"; do
		[[ -n "$r" ]] || continue
		aws iam delete-role-policy --role-name "$r" --policy-name inline >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required (pip install boto3)"

# Handlers share one zip each:
# partial — fail: bodies → batchItemFailures; others written to S3
# empty   — always {"batchItemFailures":[]} after writing all to S3
# badid   — always reports an unknown itemIdentifier
python3 - "$TMP" <<'PY'
import sys, zipfile
d = sys.argv[1]
partial = b"""const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
exports.handler = async (event) => {
  const c = new S3Client({ region: process.env.AWS_REGION || "us-east-1", forcePathStyle: true });
  const failures = [];
  for (const r of event.Records) {
    if (String(r.body).startsWith("fail:")) {
      failures.push({ itemIdentifier: r.messageId });
    } else {
      await c.send(new PutObjectCommand({ Bucket: process.env.BUCKET, Key: "got/" + r.messageId, Body: r.body }));
    }
  }
  return { batchItemFailures: failures };
};
"""
empty = b"""const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
exports.handler = async (event) => {
  const c = new S3Client({ region: process.env.AWS_REGION || "us-east-1", forcePathStyle: true });
  for (const r of event.Records) {
    await c.send(new PutObjectCommand({ Bucket: process.env.BUCKET, Key: "empty/" + r.messageId, Body: r.body }));
  }
  return { batchItemFailures: [] };
};
"""
badid = b"""exports.handler = async () => {
  return { batchItemFailures: [{ itemIdentifier: "not-in-this-batch" }] };
};
"""
for name, code in (("partial", partial), ("empty", empty), ("badid", badid)):
    with zipfile.ZipFile(f"{d}/{name}.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("index.js", code)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

mkrole() {
	aws iam create-role --role-name "$1" --assume-role-policy-document "$TRUST" >/dev/null
	ROLES+=("$1")
	aws iam put-role-policy --role-name "$1" --policy-name inline --policy-document \
		"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":$2,\"Resource\":\"*\"}]}"
}
# Echoes QueueUrl only — callers must QURLS+= in the parent shell
# (`url="$(mkqueue …)"` runs the function in a subshell).
mkqueue() {
	if [[ -n "${2:-}" ]]; then
		aws sqs create-queue --queue-name "$1" --attributes "$2" --query QueueUrl --output text
	else
		aws sqs create-queue --queue-name "$1" --query QueueUrl --output text
	fi
}
qarn() { aws sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn --query Attributes.QueueArn --output text; }
mkfn() {
	local timeout="${4:-10}"
	aws lambda create-function --function-name "$1" --runtime nodejs18.x --role "$3" \
		--handler index.handler --zip-file "fileb://$2" --timeout "$timeout" \
		--environment "Variables={BUCKET=${BUCKET}}" >/dev/null
	FNS+=("$1")
	local s=""
	for _ in $(seq 1 60); do
		s="$(aws lambda get-function --function-name "$1" --query Configuration.State --output text 2>/dev/null || echo Pending)"
		[[ "$s" == "Active" ]] && return 0
		sleep 2
	done
	fail "$1 never Active (state=${s})"
}
qcount() {
	aws sqs get-queue-attributes --queue-url "$1" \
		--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
		--query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text |
		awk '{print $1+$2}'
}
s3_count() { # prefix
	aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$1" --query 'length(Contents||`[]`)' --output text 2>/dev/null || echo 0
}
wait_esm_enabled() {
	local s=""
	for _ in $(seq 1 30); do
		s="$(aws lambda get-event-source-mapping --uuid "$1" --query State --output text)"
		[[ "$s" == "Enabled" ]] && return 0
		sleep 2
	done
	fail "mapping $1 never Enabled (state=${s})"
}
wait_dlq_bodies() { # url expected-count timeout-iters → prints bodies one per line
	local url="$1" want="$2" iters="${3:-60}"
	local bodies=""
	for _ in $(seq 1 "$iters"); do
		bodies="$(
			aws sqs receive-message --queue-url "$url" --max-number-of-messages 10 --wait-time-seconds 1 \
				--visibility-timeout 0 --query 'Messages[].Body' --output text 2>/dev/null || true
		)"
		# shellcheck disable=SC2086
		local n
		n="$(printf '%s\n' $bodies | sed '/^$/d' | wc -l | tr -d ' ')"
		[[ "$n" -ge "$want" ]] && { printf '%s\n' $bodies; return 0; }
		sleep 2
	done
	printf '%s\n' $bodies
	return 1
}

aws s3 mb "s3://${BUCKET}" >/dev/null

mkrole "${P}-role" '["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","s3:PutObject","logs:*"]'
RARN="$(aws iam get-role --role-name "${P}-role" --query Role.Arn --output text)"
mkfn "${P}-partial" "$TMP/partial.zip" "$RARN" 5
mkfn "${P}-empty" "$TMP/empty.zip" "$RARN" 5
mkfn "${P}-badid" "$TMP/badid.zip" "$RARN" 5

# ---- 1. partial batch: 3 msgs, report 1 failure → 2 deleted + 1 redelivered → DLQ ----
DLQ1="$(mkqueue "${P}-dlq1")"; QURLS+=("$DLQ1")
DARN1="$(qarn "$DLQ1")"
RP1="$(python3 -c 'import json,sys; print(json.dumps({"RedrivePolicy":json.dumps({"deadLetterTargetArn":sys.argv[1],"maxReceiveCount":2}),"VisibilityTimeout":"10"}))' "$DARN1")"
Q1="$(mkqueue "${P}-partial" "$RP1")"; QURLS+=("$Q1")
U1="$(aws lambda create-event-source-mapping --function-name "${P}-partial" \
	--event-source-arn "$(qarn "$Q1")" --batch-size 3 --maximum-batching-window-in-seconds 2 \
	--function-response-types ReportBatchItemFailures --query UUID --output text)"
UUIDS+=("$U1")
wait_esm_enabled "$U1"

aws sqs send-message --queue-url "$Q1" --message-body "ok-a-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q1" --message-body "fail:poison-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q1" --message-body "ok-b-${TS}" >/dev/null

got_ok=0
for _ in $(seq 1 45); do
	got_ok="$(s3_count "got/")"
	[[ "$got_ok" == "2" ]] && break
	sleep 2
done
[[ "$got_ok" == "2" ]] || fail "expected 2 S3 writes for successful batch items (got=${got_ok})"
ok "partial batch: 2 successes written to S3"

# Source queue should drain to 0 once the failed item hits the DLQ (maxReceiveCount=2).
n=1
for _ in $(seq 1 60); do
	n="$(qcount "$Q1")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "source queue not empty after partial retries (count=${n})"

bodies=""
if ! bodies="$(wait_dlq_bodies "$DLQ1" 1 60)"; then
	fail "failed message never reached DLQ (bodies='${bodies}')"
fi
echo "$bodies" | grep -q "fail:poison-${TS}" || fail "DLQ missing fail body (bodies='${bodies}')"
# Only the reported failure should be redriven — successes stay deleted.
echo "$bodies" | grep -q "ok-a-${TS}" && fail "ok-a incorrectly reached DLQ"
echo "$bodies" | grep -q "ok-b-${TS}" && fail "ok-b incorrectly reached DLQ"
ok "partial batch: 1 failure redelivered to DLQ after maxReceiveCount; successes stay deleted"

# ---- 2. empty batchItemFailures → whole batch deleted ----
Q2="$(mkqueue "${P}-empty" '{"VisibilityTimeout":"10"}')"; QURLS+=("$Q2")
U2="$(aws lambda create-event-source-mapping --function-name "${P}-empty" \
	--event-source-arn "$(qarn "$Q2")" --batch-size 3 --maximum-batching-window-in-seconds 2 \
	--function-response-types ReportBatchItemFailures --query UUID --output text)"
UUIDS+=("$U2")
wait_esm_enabled "$U2"
aws sqs send-message --queue-url "$Q2" --message-body "empty-1-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q2" --message-body "empty-2-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q2" --message-body "empty-3-${TS}" >/dev/null
got_empty=0
for _ in $(seq 1 45); do
	got_empty="$(s3_count "empty/")"
	[[ "$got_empty" == "3" ]] && break
	sleep 2
done
[[ "$got_empty" == "3" ]] || fail "empty-failures handler did not write all 3 (got=${got_empty})"
n=1
for _ in $(seq 1 30); do
	n="$(qcount "$Q2")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "empty batchItemFailures did not delete whole batch (count=${n})"
ok "empty batchItemFailures deletes whole batch"

# ---- 3. invalid itemIdentifier → whole batch fails → DLQ ----
DLQ3="$(mkqueue "${P}-dlq3")"; QURLS+=("$DLQ3")
DARN3="$(qarn "$DLQ3")"
RP3="$(python3 -c 'import json,sys; print(json.dumps({"RedrivePolicy":json.dumps({"deadLetterTargetArn":sys.argv[1],"maxReceiveCount":2}),"VisibilityTimeout":"10"}))' "$DARN3")"
Q3="$(mkqueue "${P}-badid" "$RP3")"; QURLS+=("$Q3")
U3="$(aws lambda create-event-source-mapping --function-name "${P}-badid" \
	--event-source-arn "$(qarn "$Q3")" --batch-size 3 --maximum-batching-window-in-seconds 2 \
	--function-response-types ReportBatchItemFailures --query UUID --output text)"
UUIDS+=("$U3")
wait_esm_enabled "$U3"
aws sqs send-message --queue-url "$Q3" --message-body "bad-1-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q3" --message-body "bad-2-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q3" --message-body "bad-3-${TS}" >/dev/null

bodies=""
if ! bodies="$(wait_dlq_bodies "$DLQ3" 3 90)"; then
	fail "invalid itemIdentifier: expected all 3 messages on DLQ (bodies='${bodies}')"
fi
for b in "bad-1-${TS}" "bad-2-${TS}" "bad-3-${TS}"; do
	echo "$bodies" | grep -q "$b" || fail "invalid itemIdentifier: DLQ missing ${b} (bodies='${bodies}')"
done
n="$(qcount "$Q3")"
[[ "$n" == "0" ]] || fail "invalid itemIdentifier: source queue not drained (count=${n})"
ok "invalid itemIdentifier fails whole batch; all messages reach DLQ"

# ---- 4. without ReportBatchItemFailures → response body ignored (all deleted) ----
DLQ4="$(mkqueue "${P}-dlq4")"; QURLS+=("$DLQ4")
DARN4="$(qarn "$DLQ4")"
RP4="$(python3 -c 'import json,sys; print(json.dumps({"RedrivePolicy":json.dumps({"deadLetterTargetArn":sys.argv[1],"maxReceiveCount":2}),"VisibilityTimeout":"10"}))' "$DARN4")"
Q4="$(mkqueue "${P}-ignore" "$RP4")"; QURLS+=("$Q4")
# Same partial handler, but mapping WITHOUT function-response-types.
U4="$(aws lambda create-event-source-mapping --function-name "${P}-partial" \
	--event-source-arn "$(qarn "$Q4")" --batch-size 3 --maximum-batching-window-in-seconds 2 \
	--query UUID --output text)"
UUIDS+=("$U4")
wait_esm_enabled "$U4"

# Use a distinct S3 prefix via message bodies; successes still land under got/.
PREFIX_BEFORE="$(s3_count "got/")"
aws sqs send-message --queue-url "$Q4" --message-body "ign-ok-a-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q4" --message-body "fail:ign-poison-${TS}" >/dev/null
aws sqs send-message --queue-url "$Q4" --message-body "ign-ok-b-${TS}" >/dev/null

# Without ReportBatchItemFailures, successes are written and the whole batch is deleted
# even though the handler listed a failure.
want=$((PREFIX_BEFORE + 2))
got_ign=0
for _ in $(seq 1 45); do
	got_ign="$(s3_count "got/")"
	[[ "$got_ign" == "$want" ]] && break
	sleep 2
done
[[ "$got_ign" == "$want" ]] || fail "ignore-response: expected ${want} S3 keys (got=${got_ign})"

n=1
for _ in $(seq 1 30); do
	n="$(qcount "$Q4")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "ignore-response: queue not empty (count=${n}) — response body may not be ignored"

# Give the poller a moment; poison must NOT land on DLQ when response is ignored.
sleep 8
dlq4="$(
	aws sqs receive-message --queue-url "$DLQ4" --max-number-of-messages 10 --wait-time-seconds 1 \
		--visibility-timeout 0 --query 'Messages[].Body' --output text 2>/dev/null || true
)"
echo "$dlq4" | grep -q "fail:ign-poison-${TS}" && fail "ignore-response: poison reached DLQ (body should be ignored; got='${dlq4}')"
ok "without ReportBatchItemFailures response body is ignored; whole batch deleted"

echo "OK: SQS→Lambda ReportBatchItemFailures partial/empty/invalid/ignored (${P})"
