#!/usr/bin/env bash
# Sad path: IAM user without sqs:SendMessage → AccessDenied.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
QNAME="awsbox-sqs-authz-${TS}"
USER="awsbox-sqs-deny-${TS}"
POLICY_NAME="AwsboxDenySqsSend-${TS}"
KEEP="${AWSBOX_SQS_KEEP:-0}"
QUEUE_URL=""
DENIED_KEY=""
POLICY_ARN=""
TMPDIR="${TMPDIR:-/tmp}"
POLICY_DOC="${TMPDIR}/awsbox-deny-sqs-$$.json"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	rm -f "$POLICY_DOC"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
	if [[ -n "$DENIED_KEY" ]]; then
		aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	fi
	if [[ -n "$POLICY_ARN" ]]; then
		aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
		aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	fi
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

QUEUE_URL="$(
	aws sqs create-queue --queue-name "$QNAME" --query 'QueueUrl' --output text
)"

cat >"$POLICY_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenySend",
      "Effect": "Deny",
      "Action": "sqs:SendMessage",
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(
	aws iam create-policy \
		--policy-name "$POLICY_NAME" \
		--policy-document "file://${POLICY_DOC}" \
		--query 'Policy.Arn' --output text
)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null

KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

set +e
OUT="$(
	AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
		aws sqs send-message \
			--queue-url "$QUEUE_URL" \
			--message-body "should-deny" \
			2>&1
)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
	echo "FAIL: send succeeded; expected AccessDenied" >&2
	echo "$OUT" >&2
	exit 1
fi
if ! echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized'; then
	echo "FAIL: expected AccessDenied in output:" >&2
	echo "$OUT" >&2
	exit 1
fi

echo "OK: SQS SendMessage AccessDenied under deny-user (${QNAME})"
echo "$OUT" | head -2
