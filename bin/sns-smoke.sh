#!/usr/bin/env bash
# Happy: create topic → publish → (optional SQS sub) → delete topic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TOPIC="awsbox-sns-${TS}"
KEEP="${AWSBOX_SNS_KEEP:-0}"
TOPIC_ARN=""
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
}
trap cleanup EXIT
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)"
MSG_ID="$(aws sns publish --topic-arn "$TOPIC_ARN" --message "awsbox-sns-${TS}" --query 'MessageId' --output text)"
[[ -n "$MSG_ID" && "$MSG_ID" != "None" ]]
aws sns get-topic-attributes --topic-arn "$TOPIC_ARN" --query 'Attributes.DisplayName' --output text >/dev/null
echo "OK: sns create/publish (${TOPIC} msg=${MSG_ID})"
