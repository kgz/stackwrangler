#!/usr/bin/env bash
# Happy path: create queue → send → receive → delete message → delete queue.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
QNAME="awsbox-sqs-${TS}"
KEEP="${AWSBOX_SQS_KEEP:-0}"
QUEUE_URL=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

QUEUE_URL="$(
	aws sqs create-queue --queue-name "$QNAME" --query 'QueueUrl' --output text
)"
[[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]]

BODY="awsbox-sqs-smoke-${TS}"
aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$BODY" >/dev/null

RECV=""
for _ in $(seq 1 20); do
	RECV="$(
		aws sqs receive-message \
			--queue-url "$QUEUE_URL" \
			--max-number-of-messages 1 \
			--wait-time-seconds 1 \
			--output json
	)"
	echo "$RECV" | grep -q "$BODY" && break
	sleep 1
done
echo "$RECV" | grep -q "$BODY"

HANDLE="$(echo "$RECV" | python3 -c '
import json,sys
ms=json.load(sys.stdin).get("Messages") or []
assert ms, "no messages"
print(ms[0]["ReceiptHandle"])
')"
aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$HANDLE" >/dev/null

echo "OK: sqs send/receive/delete (${QNAME})"
