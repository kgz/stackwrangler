#!/usr/bin/env bash
# Sad: deny-user sns:Publish → AccessDenied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TOPIC="awsbox-sns-authz-${TS}"
USER="awsbox-sns-deny-${TS}"
POLICY_NAME="AwsboxDenySnsPublish-${TS}"
KEEP="${AWSBOX_SNS_KEEP:-0}"
TOPIC_ARN="" DENIED_KEY="" POLICY_ARN=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-sns-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$POLICY_DOC"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)"
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"sns:Publish","Resource":"*"}]}
EOF
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" aws sns publish --topic-arn "$TOPIC_ARN" --message should-deny 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: publish succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' || { echo "FAIL: $OUT" >&2; exit 1; }
echo "OK: SNS Publish AccessDenied (${TOPIC})"
echo "$OUT" | head -2
