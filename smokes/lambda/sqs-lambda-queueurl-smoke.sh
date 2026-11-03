#!/usr/bin/env bash
# Lambda SendMessage using the QueueUrl from CreateQueue (sqs.<region>.localhost).
# Mirrors !Ref Queue / stack-output env injection; SDK v3 must resolve that host
# inside the Lambda container (#459).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="awsbox-qurl-${TS}"
KEEP="${STACKWRANGLER_AUTHZ_KEEP:-${AWSBOX_AUTHZ_KEEP:-0}}"
TMP="$(mktemp -d)"
OUT="$TMP/invoke.json"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

FN="" QURL="" ROLE=""
cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$FN" ]] && aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	if [[ -n "$ROLE" ]]; then
		aws iam delete-role-policy --role-name "$ROLE" --policy-name inline >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 - "$TMP" <<'PY'
import sys, zipfile
code = b"""const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
exports.handler = async (event) => {
  const QueueUrl = process.env.QUEUE_URL;
  const client = new SQSClient({});
  await client.send(new SendMessageCommand({
    QueueUrl,
    MessageBody: event.body || "ping",
  }));
  return { ok: true, QueueUrl };
};
"""
with zipfile.ZipFile(f"{sys.argv[1]}/fn.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE="${P}-role"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name inline --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sqs:SendMessage","logs:*"],"Resource":"*"}]}'
RARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

QURL="$(aws sqs create-queue --queue-name "${P}-q" --query QueueUrl --output text)"
[[ -n "$QURL" && "$QURL" != "None" ]] || fail "CreateQueue returned empty QueueUrl"
case "$QURL" in
	*"sqs.${REGION}."*) ok "CreateQueue QueueUrl uses sqs.${REGION}.* host ($QURL)" ;;
	*) fail "expected standard QueueUrl host sqs.${REGION}.* got: $QURL" ;;
esac

FN="${P}-fn"
aws lambda create-function --function-name "$FN" --runtime nodejs18.x --role "$RARN" \
	--handler index.handler --zip-file "fileb://${TMP}/fn.zip" --timeout 20 \
	--environment "Variables={QUEUE_URL=${QURL}}" >/dev/null

for _ in $(seq 1 60); do
	[[ "$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text)" == "Active" ]] && break
	sleep 2
done
[[ "$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text)" == "Active" ]] \
	|| fail "function never Active"

BODY="qurl-${TS}"
META="$(aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	--payload "{\"body\":\"${BODY}\"}" "$OUT")"
PAYLOAD="$(cat "$OUT")"
if echo "$META" | grep -q FunctionError; then
	fail "invoke FunctionError (meta=${META}; payload=${PAYLOAD})"
fi
if echo "$PAYLOAD" | grep -qiE 'ENOTFOUND|getaddrinfo'; then
	fail "Lambda could not resolve QueueUrl host (payload=${PAYLOAD})"
fi
echo "$PAYLOAD" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' \
	|| fail "handler did not return ok (payload=${PAYLOAD})"

got=""
for _ in $(seq 1 20); do
	got="$(aws sqs receive-message --queue-url "$QURL" --wait-time-seconds 1 \
		--max-number-of-messages 1 --query 'Messages[0].Body' --output text 2>/dev/null || true)"
	[[ "$got" == "$BODY" ]] && break
	sleep 1
done
[[ "$got" == "$BODY" ]] || fail "message never arrived on queue (got='${got}')"
ok "Lambda SendMessage via CreateQueue QueueUrl; message received"
