#!/usr/bin/env bash
# SQS -> Lambda event source mapping: success path (Lambda writes S3 object, message deleted),
# redrive to DLQ (maxReceiveCount 2, Lambda always throws), and sad/authz path
# (execution role without SQS read perms -> CreateEventSourceMapping refused, as in real AWS).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
P="awsbox-esm-${TS}"
BUCKET="${P}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
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

# Handlers: "ok" writes one S3 object per message; "boom" always throws.
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
boom = b"""exports.handler = async () => { throw new Error("boom"); };
"""
for name, code in (("ok", ok), ("boom", boom)):
    with zipfile.ZipFile(f"{d}/{name}.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("index.js", code)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
# $1 role name, $2 inline policy actions (JSON array)
mkrole() {
	aws iam create-role --role-name "$1" --assume-role-policy-document "$TRUST" >/dev/null
	ROLES+=("$1")
	aws iam put-role-policy --role-name "$1" --policy-name inline --policy-document \
		"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":$2,\"Resource\":\"*\"}]}"
}
mkqueue() { # name [attrs-json]
	local u
	if [[ -n "${2:-}" ]]; then
		u="$(aws sqs create-queue --queue-name "$1" --attributes "$2" --query QueueUrl --output text)"
	else
		u="$(aws sqs create-queue --queue-name "$1" --query QueueUrl --output text)"
	fi
	QURLS+=("$u")
	echo "$u"
}
qarn() { aws sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn --query Attributes.QueueArn --output text; }
mkfn() { # name zip role-arn [env-json]
	aws lambda create-function --function-name "$1" --runtime nodejs18.x --role "$3" \
		--handler index.handler --zip-file "fileb://$2" --timeout 20 \
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
qcount() { # url -> visible+inflight
	aws sqs get-queue-attributes --queue-url "$1" \
		--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
		--query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text |
		awk '{print $1+$2}'
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

aws s3 mb "s3://${BUCKET}" >/dev/null

# ---- 1. happy: message -> Lambda -> S3 object, message deleted ----
mkrole "${P}-role" '["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","s3:PutObject","logs:*"]'
RARN="$(aws iam get-role --role-name "${P}-role" --query Role.Arn --output text)"
Q1="$(mkqueue "${P}-in" '{"VisibilityTimeout":"30"}')"
mkfn "${P}-ok" "$TMP/ok.zip" "$RARN"
U1="$(aws lambda create-event-source-mapping --function-name "${P}-ok" \
	--event-source-arn "$(qarn "$Q1")" --batch-size 1 --query UUID --output text)"
UUIDS+=("$U1")
wait_esm_enabled "$U1"
aws sqs send-message --queue-url "$Q1" --message-body "hello-${TS}" >/dev/null
got=""
for _ in $(seq 1 45); do
	k="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix got/ --query 'Contents[0].Key' --output text 2>/dev/null || true)"
	if [[ -n "$k" && "$k" != "None" ]]; then
		got="$(aws s3 cp "s3://${BUCKET}/${k}" - 2>/dev/null || true)"
		break
	fi
	sleep 2
done
[[ "$got" == "hello-${TS}" ]] || fail "Lambda did not write message body to S3 (got='${got}')"
ok "SQS message invoked Lambda; body written to S3"
n=1
for _ in $(seq 1 15); do
	n="$(qcount "$Q1")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "message not deleted from queue after successful invoke (count=${n})"
ok "message deleted from source queue after success"

# ---- 2. redrive: always-throwing Lambda, maxReceiveCount 2 -> DLQ ----
DLQ="$(mkqueue "${P}-dlq")"
DARN="$(qarn "$DLQ")"
RP="$(python3 -c 'import json,sys; print(json.dumps({"RedrivePolicy":json.dumps({"deadLetterTargetArn":sys.argv[1],"maxReceiveCount":2}),"VisibilityTimeout":"2"}))' "$DARN")"
Q2="$(mkqueue "${P}-redrive" "$RP")"
mkfn "${P}-boom" "$TMP/boom.zip" "$RARN"
U2="$(aws lambda create-event-source-mapping --function-name "${P}-boom" \
	--event-source-arn "$(qarn "$Q2")" --batch-size 1 --query UUID --output text)"
UUIDS+=("$U2")
wait_esm_enabled "$U2"
aws sqs send-message --queue-url "$Q2" --message-body "poison-${TS}" >/dev/null
body=""
for _ in $(seq 1 45); do
	body="$(aws sqs receive-message --queue-url "$DLQ" --wait-time-seconds 1 --query 'Messages[0].Body' --output text 2>/dev/null || true)"
	[[ "$body" == "poison-${TS}" ]] && break
	sleep 2
done
[[ "$body" == "poison-${TS}" ]] || fail "poison message never reached DLQ (got='${body}')"
ok "failing Lambda: message moved to DLQ after maxReceiveCount=2"

# ---- 3. sad/authz: role without SQS read perms -> mapping refused ----
mkrole "${P}-norole" '["s3:PutObject","logs:*"]'
NARN="$(aws iam get-role --role-name "${P}-norole" --query Role.Arn --output text)"
Q3="$(mkqueue "${P}-denied")"
mkfn "${P}-noperm" "$TMP/ok.zip" "$NARN"
set +e
OUT="$(aws lambda create-event-source-mapping --function-name "${P}-noperm" \
	--event-source-arn "$(qarn "$Q3")" --batch-size 1 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
	u="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("UUID",""))' 2>/dev/null || true)"
	[[ -n "$u" ]] && UUIDS+=("$u")
	fail "CreateEventSourceMapping succeeded with role lacking SQS perms; real AWS returns InvalidParameterValueException"
fi
echo "$OUT" | grep -q 'InvalidParameterValueException' || fail "expected InvalidParameterValueException, got: $OUT"
echo "$OUT" | grep -qi 'ReceiveMessage\|execution role' || fail "error does not mention execution role/ReceiveMessage: $OUT"
ok "role without SQS perms: CreateEventSourceMapping refused (InvalidParameterValueException)"

echo "OK: SQS->Lambda mapping, DLQ redrive, authz refusal (${P})"
