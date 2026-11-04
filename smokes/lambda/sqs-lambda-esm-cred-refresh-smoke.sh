#!/usr/bin/env bash
# SQS -> Lambda ESM keeps polling past STS session expiry (#475).
# Requires LocalEmu with AWSBOX_STS_ASSUME_ROLE_DURATION set short (compose / .env).
# RefreshableCredentials re-assume before expiry; LastProcessingResult surfaces
# failures when re-assume can no longer succeed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="awsbox-esm-cred-${TS}"
BUCKET="${P}"
KEEP="${STACKWRANGLER_ESM_CRED_KEEP:-${AWSBOX_ESM_CRED_KEEP:-0}}"
# Session length the emulator was started with (must match compose env).
DURATION="${STACKWRANGLER_STS_ASSUME_ROLE_DURATION:-${AWSBOX_STS_ASSUME_ROLE_DURATION:-120}}"
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

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required for sqs-lambda-esm-cred-refresh-smoke"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 30 ]]; then
	fail "AWSBOX_STS_ASSUME_ROLE_DURATION must be an integer >= 30 (got '${DURATION}'). Start LocalEmu with e.g. AWSBOX_STS_ASSUME_ROLE_DURATION=120"
fi

# Confirm the running emulator honours the knob (health is up; probe via a throwaway assume).
probe_exp="$(
	python3 - "$EP" "$REGION" "$DURATION" <<'PY'
import sys, boto3
from datetime import datetime, timezone
ep, region, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
iam = boto3.client("iam", endpoint_url=ep, region_name=region)
sts = boto3.client("sts", endpoint_url=ep, region_name=region)
name = "awsbox-esm-cred-probe"
trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"}]}'
try:
    iam.create_role(RoleName=name, AssumeRolePolicyDocument=trust)
except Exception:
    pass
arn = iam.get_role(RoleName=name)["Role"]["Arn"]
creds = sts.assume_role(RoleArn=arn, RoleSessionName="probe")["Credentials"]
exp = creds["Expiration"]
if getattr(exp, "tzinfo", None) is None:
    exp = exp.replace(tzinfo=timezone.utc)
secs = (exp - datetime.now(timezone.utc)).total_seconds()
iam.delete_role(RoleName=name)
# Allow some skew; default LocalEmu without the knob is ~3600s.
print(int(secs))
if secs > want * 2 and secs > 600:
    sys.exit(2)
PY
)" || fail "emulator AssumeRole sessions look ~1h — recreate LocalEmu with AWSBOX_STS_ASSUME_ROLE_DURATION=${DURATION} (probe remaining≈${probe_exp:-?}s)"
ok "STS session probe remaining≈${probe_exp}s (want ~${DURATION}s)"

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
esm_state() {
	aws lambda get-event-source-mapping --uuid "$1" --query State --output text
}
esm_lpr() {
	aws lambda get-event-source-mapping --uuid "$1" --query LastProcessingResult --output text 2>/dev/null || true
}
wait_esm_state() {
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
has_body() {
	s3_bodies | grep -Fqx "$1"
}
wait_body() {
	local body="$1" secs="${2:-60}" got=""
	for _ in $(seq 1 "$secs"); do
		if has_body "$body"; then
			echo "$body"
			return 0
		fi
		sleep 2
	done
	return 1
}

aws s3 mb "s3://${BUCKET}" >/dev/null

ROLE="${P}-role"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name inline --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","s3:PutObject","logs:*"],"Resource":"*"}]}'
RARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

QURL="$(aws sqs create-queue --queue-name "${P}-in" \
	--attributes '{"VisibilityTimeout":"30","MessageRetentionPeriod":"1200"}' \
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

aws sqs send-message --queue-url "$QURL" --message-body "prime-${TS}" >/dev/null
wait_body "prime-${TS}" 45 >/dev/null || fail "baseline: Lambda did not consume prime message"
n=1
for _ in $(seq 1 15); do
	n="$(qcount "$QURL")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "baseline: prime message still in queue (count=${n})"
ok "baseline consume works"

# Wait past one full session (+ buffer) so frozen credentials would have expired.
WAIT_SECS=$((DURATION + DURATION / 2 + 15))
echo "waiting ${WAIT_SECS}s past STS session (${DURATION}s) for credential refresh…"
sleep "$WAIT_SECS"

aws sqs send-message --queue-url "$QURL" --message-body "after-expiry-${TS}" >/dev/null
wait_body "after-expiry-${TS}" 60 >/dev/null || fail "after session expiry: Lambda did not consume (credentials not refreshed?)"
n=1
for _ in $(seq 1 15); do
	n="$(qcount "$QURL")"
	[[ "$n" == "0" ]] && break
	sleep 2
done
[[ "$n" == "0" ]] || fail "after expiry: message still in queue (count=${n})"
st="$(esm_state "$UUID")"
[[ "$st" == "Enabled" ]] || fail "mapping left Enabled after refresh path (state=${st})"
ok "consume still works past STS session expiry (refresh)"

# Break re-assume: delete the execution role so the next refresh fails, then wait
# for the current session to die and assert LastProcessingResult surfaces it.
aws iam delete-role-policy --role-name "$ROLE" --policy-name inline >/dev/null 2>&1 || true
aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
ROLE=""
echo "waiting ${WAIT_SECS}s for refreshed session to expire after role delete…"
sleep "$WAIT_SECS"

aws sqs send-message --queue-url "$QURL" --message-body "orphan-${TS}" >/dev/null || true
saw_lpr=""
for _ in $(seq 1 45); do
	lpr="$(esm_lpr "$UUID")"
	case "$lpr" in
		PROBLEM:*|*"ExpiredToken"*|*"AccessDenied"*|*"NoSuchEntity"*)
			saw_lpr="$lpr"
			break
			;;
	esac
	sleep 2
done
[[ -n "$saw_lpr" ]] || fail "expected LastProcessingResult PROBLEM after role delete (lpr='$(esm_lpr "$UUID")')"
ok "LastProcessingResult surfaces credential failure (${saw_lpr})"

# Message should still be in the queue (poller cannot consume).
n="$(qcount "$QURL")"
[[ "$n" != "0" ]] || fail "orphan message missing — poller should have stopped after role delete"
ok "queue retained message while poller cannot refresh credentials"

echo "OK: ESM credential refresh past expiry + LastProcessingResult on hard fail (${P})"
