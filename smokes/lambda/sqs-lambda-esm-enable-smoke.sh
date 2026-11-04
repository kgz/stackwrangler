#!/usr/bin/env bash
# SQS -> Lambda ESM enable/disable kill switch (#446).
# Disable stops polling (messages stay visible); re-enable drains the backlog;
# messages past MessageRetentionPeriod while disabled are gone, not delivered.
# Intermediate Disabling/Enabling may be fleeting on LocalEmu — soft-check only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}}"
TS="$(date +%s)"
P="awsbox-esm-en-${TS}"
BUCKET="${P}"
KEEP="${STACKWRANGLER_ESM_ENABLE_KEEP:-${AWSBOX_ESM_ENABLE_KEEP:-0}}"
# AWS minimum MessageRetentionPeriod is 60s; wait a little past that for expiry.
RETENTION_WAIT="${AWSBOX_ESM_RETENTION_WAIT:-70}"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

UUID=""
FN=""
QURL=""
ROLE=""
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$UUID" ]] && aws lambda delete-event-source-mapping --uuid "$UUID" >/dev/null 2>&1 || true
	[[ -n "$FN" ]] && aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	if [[ -n "$ROLE" ]]; then
		aws iam delete-role-policy --role-name "$ROLE" --policy-name inline >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	fi
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required for sqs-lambda-esm-enable-smoke (pip install boto3)"

python3 - "$TMP" <<'PY'
import sys, zipfile
d = sys.argv[1]
ok = b"""const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
exports.handler = async (event) => {
  const c = new S3Client({ region: process.env.AWS_REGION || "us-east-1", forcePathStyle: true });
  for (const r of event.Records) {
    await c.send(new PutObjectCommand({ Bucket: process.env.BUCKET, Key: "got/" + r.messageId, Body: r.body }));
  }
};
"""
with zipfile.ZipFile(f"{d}/ok.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", ok)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

qcount() {
	aws sqs get-queue-attributes --queue-url "$1" \
		--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
		--query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text |
		awk '{print $1+$2}'
}
visible() {
	aws sqs get-queue-attributes --queue-url "$1" \
		--attribute-names ApproximateNumberOfMessages \
		--query 'Attributes.ApproximateNumberOfMessages' --output text
}
esm_state() {
	aws lambda get-event-source-mapping --uuid "$1" --query State --output text
}
wait_esm_state() { # uuid want [secs]
	local want="$2" secs="${3:-60}" s=""
	for _ in $(seq 1 "$secs"); do
		s="$(esm_state "$1")"
		[[ "$s" == "$want" ]] && return 0
		sleep 1
	done
	fail "mapping $1 never ${want} (state=${s})"
}
s3_bodies() {
	aws s3api list-objects-v2 --bucket "$BUCKET" --prefix got/ --query 'Contents[].Key' --output text 2>/dev/null |
		tr '\t' '\n' | while read -r k; do
			[[ -z "$k" || "$k" == "None" ]] && continue
			aws s3 cp "s3://${BUCKET}/${k}" - 2>/dev/null || true
			echo
		done
}
has_body() { # needle
	s3_bodies | grep -Fqx "$1"
}

aws s3 mb "s3://${BUCKET}" >/dev/null

ROLE="${P}-role"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name inline --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","s3:PutObject","logs:*"],"Resource":"*"}]}'
RARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

# MRP=60 (AWS min) so expiry while disabled finishes in one smoke run.
QURL="$(aws sqs create-queue --queue-name "${P}-in" \
	--attributes '{"VisibilityTimeout":"30","MessageRetentionPeriod":"60"}' \
	--query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

FN="${P}-ok"
aws lambda create-function --function-name "$FN" --runtime nodejs18.x --role "$RARN" \
	--handler index.handler --zip-file "fileb://${TMP}/ok.zip" --timeout 20 \
	--environment "Variables={BUCKET=${BUCKET}}" >/dev/null
for _ in $(seq 1 60); do
	s="$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text 2>/dev/null || echo Pending)"
	[[ "$s" == "Active" ]] && break
	sleep 2
done
[[ "$s" == "Active" ]] || fail "$FN never Active (state=${s})"

UUID="$(aws lambda create-event-source-mapping --function-name "$FN" \
	--event-source-arn "$QARN" --batch-size 1 --query UUID --output text)"
wait_esm_state "$UUID" Enabled 60
ok "mapping Enabled"

# Prove consume works before the kill switch.
aws sqs send-message --queue-url "$QURL" --message-body "prime-${TS}" >/dev/null
got=""
for _ in $(seq 1 45); do
	if has_body "prime-${TS}"; then got="prime-${TS}"; break; fi
	sleep 2
done
[[ "$got" == "prime-${TS}" ]] || fail "baseline: Lambda did not consume prime message"
n=1
for _ in $(seq 1 15); do
	n="$(qcount "$QURL")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "baseline: prime message still in queue (count=${n})"
ok "baseline consume works"

# ---- disable: Disabling -> Disabled; new messages not consumed ----
aws lambda update-event-source-mapping --uuid "$UUID" --no-enabled >/dev/null
# Intermediate Disabling is often too fast to observe; soft-check only.
saw_disabling=0
for _ in $(seq 1 5); do
	s="$(esm_state "$UUID")"
	[[ "$s" == "Disabling" ]] && saw_disabling=1
	[[ "$s" == "Disabled" ]] && break
	sleep 1
done
wait_esm_state "$UUID" Disabled 30
if [[ "$saw_disabling" == "1" ]]; then
	ok "State Disabling -> Disabled"
else
	ok "State Disabled (Disabling not observed — ok on LocalEmu)"
fi

aws sqs send-message --queue-url "$QURL" --message-body "expire-${TS}" >/dev/null
# Hold window while disabled so expire can hit MessageRetentionPeriod=60.
echo "waiting ${RETENTION_WAIT}s for MessageRetentionPeriod expiry while Disabled…"
sleep "$RETENTION_WAIT"
n="$(qcount "$QURL")"
[[ "$n" == "0" ]] || fail "expire message still in queue after retention wait (count=${n})"
ok "message past MessageRetentionPeriod gone from queue while Disabled"

# Raise retention so the hold message cannot expire during re-enable/drain.
aws sqs set-queue-attributes --queue-url "$QURL" \
	--attributes MessageRetentionPeriod=345600 >/dev/null

aws sqs send-message --queue-url "$QURL" --message-body "hold-${TS}" >/dev/null
# Give the (stopped) poller time to wrongly consume if disable is broken.
sleep 8
v="$(visible "$QURL")"
[[ "$v" != "0" ]] || fail "hold message missing from queue while Disabled (visible=${v})"
if has_body "hold-${TS}"; then
	fail "hold message was consumed while mapping Disabled"
fi
if has_body "expire-${TS}"; then
	fail "expired message was delivered after retention"
fi
ok "while Disabled: hold stays visible; expire not delivered"

# ---- re-enable: Enabling -> Enabled; backlog drains ----
aws lambda update-event-source-mapping --uuid "$UUID" --enabled >/dev/null
saw_enabling=0
for _ in $(seq 1 5); do
	s="$(esm_state "$UUID")"
	[[ "$s" == "Enabling" ]] && saw_enabling=1
	[[ "$s" == "Enabled" ]] && break
	sleep 1
done
wait_esm_state "$UUID" Enabled 60
if [[ "$saw_enabling" == "1" ]]; then
	ok "State Enabling -> Enabled"
else
	ok "State Enabled (Enabling not observed — ok on LocalEmu)"
fi

got=""
for _ in $(seq 1 45); do
	if has_body "hold-${TS}"; then got="hold-${TS}"; break; fi
	sleep 2
done
[[ "$got" == "hold-${TS}" ]] || fail "re-enable: hold backlog not drained to Lambda/S3"
n=1
for _ in $(seq 1 15); do
	n="$(qcount "$QURL")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "re-enable: backlog not drained (count=${n})"
if has_body "expire-${TS}"; then
	fail "expired message was delivered after re-enable"
fi
ok "re-enable drained hold backlog; expire never delivered"

echo "OK: ESM disable stops polling; re-enable drains; retention drops expired (${P})"
