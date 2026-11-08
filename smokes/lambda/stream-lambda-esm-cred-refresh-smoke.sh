#!/usr/bin/env bash
# Kinesis + DynamoDB stream -> Lambda ESM keep polling past STS session expiry (#477).
# Requires LocalEmu with AWSBOX_STS_ASSUME_ROLE_DURATION set short (compose / .env).
# SQS path + LastProcessingResult hard-fail: sqs-lambda-esm-cred-refresh-smoke.sh (#475).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="awsbox-stream-esm-cred-${TS}"
BUCKET="${P}"
KEEP="${STACKWRANGLER_ESM_CRED_KEEP:-${AWSBOX_ESM_CRED_KEEP:-0}}"
DURATION="${STACKWRANGLER_STS_ASSUME_ROLE_DURATION:-${AWSBOX_STS_ASSUME_ROLE_DURATION:-120}}"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

UUID_K=""
UUID_D=""
FN=""
STREAM=""
TABLE=""
ROLE=""
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$UUID_K" ]] && aws lambda delete-event-source-mapping --uuid "$UUID_K" >/dev/null 2>&1 || true
	[[ -n "$UUID_D" ]] && aws lambda delete-event-source-mapping --uuid "$UUID_D" >/dev/null 2>&1 || true
	[[ -n "$FN" ]] && aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$STREAM" ]] && aws kinesis delete-stream --stream-name "$STREAM" >/dev/null 2>&1 || true
	[[ -n "$TABLE" ]] && aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
	if [[ -n "$ROLE" ]]; then
		aws iam delete-role-policy --role-name "$ROLE" --policy-name inline >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	fi
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required for stream-lambda-esm-cred-refresh-smoke"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 30 ]]; then
	fail "AWSBOX_STS_ASSUME_ROLE_DURATION must be an integer >= 30 (got '${DURATION}'). Start LocalEmu with e.g. AWSBOX_STS_ASSUME_ROLE_DURATION=120"
fi

probe_exp="$(
	python3 - "$EP" "$REGION" "$DURATION" <<'PY'
import sys, boto3
from datetime import datetime, timezone
ep, region, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
iam = boto3.client("iam", endpoint_url=ep, region_name=region)
sts = boto3.client("sts", endpoint_url=ep, region_name=region)
name = "awsbox-stream-esm-cred-probe"
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
  for (const r of event.Records || []) {
    let key;
    let body;
    if (r.kinesis && r.kinesis.data) {
      body = Buffer.from(r.kinesis.data, "base64").toString("utf8");
      key = "got/kinesis-" + body;
    } else if (r.dynamodb && r.dynamodb.NewImage && r.dynamodb.NewImage.pk) {
      body = r.dynamodb.NewImage.pk.S;
      key = "got/ddb-" + body;
    } else {
      continue;
    }
    await c.send(new PutObjectCommand({ Bucket: process.env.BUCKET, Key: key, Body: body }));
  }
};
"""
with zipfile.ZipFile(f"{d}/ok.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", ok)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

esm_state() {
	aws lambda get-event-source-mapping --uuid "$1" --query State --output text
}
wait_esm_state() {
	local want="$2" secs="${3:-90}" s=""
	for _ in $(seq 1 "$secs"); do
		s="$(esm_state "$1")"
		[[ "$s" == "$want" ]] && return 0
		sleep 1
	done
	fail "mapping $1 never ${want} (state=${s})"
}
has_key() {
	aws s3api head-object --bucket "$BUCKET" --key "$1" >/dev/null 2>&1
}
wait_key() {
	local key="$1" secs="${2:-90}"
	for _ in $(seq 1 "$secs"); do
		if has_key "$key"; then
			echo "$key"
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
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["kinesis:DescribeStream","kinesis:DescribeStreamSummary","kinesis:GetRecords","kinesis:GetShardIterator","kinesis:ListShards","kinesis:ListStreams","kinesis:SubscribeToShard","dynamodb:DescribeStream","dynamodb:GetRecords","dynamodb:GetShardIterator","dynamodb:ListStreams","s3:PutObject","logs:*"],"Resource":"*"}]}'
RARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

STREAM="${P}-kin"
aws kinesis create-stream --stream-name "$STREAM" --shard-count 1 >/dev/null
for _ in $(seq 1 60); do
	st="$(aws kinesis describe-stream-summary --stream-name "$STREAM" --query StreamDescriptionSummary.StreamStatus --output text 2>/dev/null \
		|| aws kinesis describe-stream --stream-name "$STREAM" --query StreamDescription.StreamStatus --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
[[ "$st" == "ACTIVE" ]] || fail "kinesis stream never ACTIVE (status=${st})"
KARN="$(aws kinesis describe-stream --stream-name "$STREAM" --query StreamDescription.StreamARN --output text)"

TABLE="${P}-ddb"
aws dynamodb create-table \
	--table-name "$TABLE" \
	--attribute-definitions AttributeName=pk,AttributeType=S \
	--key-schema AttributeName=pk,KeyType=HASH \
	--billing-mode PAY_PER_REQUEST \
	--stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE >/dev/null
for _ in $(seq 1 60); do
	st="$(aws dynamodb describe-table --table-name "$TABLE" --query Table.TableStatus --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
[[ "$st" == "ACTIVE" ]] || fail "dynamodb table never ACTIVE (status=${st})"
DARN="$(aws dynamodb describe-table --table-name "$TABLE" --query Table.LatestStreamArn --output text)"
[[ -n "$DARN" && "$DARN" != "None" ]] || fail "dynamodb LatestStreamArn missing"

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

UUID_K="$(aws lambda create-event-source-mapping --function-name "$FN" \
	--event-source-arn "$KARN" --starting-position LATEST --batch-size 1 --query UUID --output text)"
UUID_D="$(aws lambda create-event-source-mapping --function-name "$FN" \
	--event-source-arn "$DARN" --starting-position LATEST --batch-size 1 --query UUID --output text)"
wait_esm_state "$UUID_K" Enabled 90
wait_esm_state "$UUID_D" Enabled 90
ok "kinesis + dynamodb stream mappings Enabled"

# Brief settle so LATEST iterators are past create-time races.
sleep 3

DATA_FILE="${TMP}/prime.bin"
printf 'prime-kinesis-%s' "$TS" >"$DATA_FILE"
aws kinesis put-record --stream-name "$STREAM" --partition-key pk --data "fileb://${DATA_FILE}" >/dev/null
aws dynamodb put-item --table-name "$TABLE" --item "{\"pk\":{\"S\":\"prime-ddb-${TS}\"}}" >/dev/null

wait_key "got/kinesis-prime-kinesis-${TS}" 90 >/dev/null || fail "baseline: Kinesis record not delivered"
wait_key "got/ddb-prime-ddb-${TS}" 90 >/dev/null || fail "baseline: DynamoDB stream record not delivered"
ok "baseline stream consume works"

WAIT_SECS=$((DURATION + DURATION / 2 + 15))
echo "waiting ${WAIT_SECS}s past STS session (${DURATION}s) for credential refresh…"
sleep "$WAIT_SECS"

printf 'after-expiry-kinesis-%s' "$TS" >"$DATA_FILE"
aws kinesis put-record --stream-name "$STREAM" --partition-key pk --data "fileb://${DATA_FILE}" >/dev/null
aws dynamodb put-item --table-name "$TABLE" --item "{\"pk\":{\"S\":\"after-expiry-ddb-${TS}\"}}" >/dev/null

wait_key "got/kinesis-after-expiry-kinesis-${TS}" 90 >/dev/null || fail "after session expiry: Kinesis not delivered (credentials not refreshed?)"
wait_key "got/ddb-after-expiry-ddb-${TS}" 90 >/dev/null || fail "after session expiry: DynamoDB stream not delivered (credentials not refreshed?)"

st_k="$(esm_state "$UUID_K")"
st_d="$(esm_state "$UUID_D")"
[[ "$st_k" == "Enabled" ]] || fail "kinesis mapping left Enabled after refresh path (state=${st_k})"
[[ "$st_d" == "Enabled" ]] || fail "dynamodb mapping left Enabled after refresh path (state=${st_d})"
ok "stream consume still works past STS session expiry (refresh)"

echo "OK: stream ESM credential refresh past expiry (kinesis + dynamodb) (${P})"
