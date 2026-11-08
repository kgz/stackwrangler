#!/usr/bin/env bash
# sns:Protocol / sns:Endpoint on Subscribe (#518).
# Happy: role may subscribe intake-queue over sqs.
# Sad: other-queue denied; --protocol https denied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_SESSION_TOKEN
TS="$(date +%s)"
KEEP="${AWSBOX_SNS_KEEP:-0}"
TOPIC="events-topic-${TS}"
INTAKE="intake-queue-${TS}"
OTHER="other-queue-${TS}"
ROLE="awsbox-sns-sub-${TS}"
TOPIC_ARN="" INTAKE_URL="" OTHER_URL="" INTAKE_ARN="" OTHER_ARN="" ROLE_ARN=""
WORK="${TMPDIR:-/tmp}/awsbox-sns-sub-$$"
mkdir -p "$WORK"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
as_role() {
	AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
		aws "$@"
}
cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$ROLE_ARN" ]] && aws iam delete-role-policy --role-name "$ROLE" --policy-name allow >/dev/null 2>&1 || true
	[[ -n "$ROLE_ARN" ]] && aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$INTAKE_URL" ]] && aws sqs delete-queue --queue-url "$INTAKE_URL" >/dev/null 2>&1 || true
	[[ -n "$OTHER_URL" ]] && aws sqs delete-queue --queue-url "$OTHER_URL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)"
INTAKE_URL="$(aws sqs create-queue --queue-name "$INTAKE" --query QueueUrl --output text)"
OTHER_URL="$(aws sqs create-queue --queue-name "$OTHER" --query QueueUrl --output text)"
INTAKE_ARN="$(aws sqs get-queue-attributes --queue-url "$INTAKE_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
OTHER_ARN="$(aws sqs get-queue-attributes --queue-url "$OTHER_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
ACCT="$(python3 -c 'import sys; print(sys.argv[1].split(":")[4])' "$TOPIC_ARN")"

python3 - "$WORK/trust.json" "$ACCT" <<'PY'
import json, sys
path, acct = sys.argv[1], sys.argv[2]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam::{acct}:root"},
        "Action": "sts:AssumeRole",
    }],
}, open(path, "w"))
PY
python3 - "$WORK/allow.json" "$TOPIC_ARN" "$INTAKE_ARN" <<'PY'
import json, sys
path, topic, intake = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "sns:Subscribe",
        "Resource": topic,
        "Condition": {
            "StringEquals": {"sns:Protocol": "sqs"},
            "StringLike": {"sns:Endpoint": intake},
        },
    }],
}, open(path, "w"))
PY

aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://${WORK}/trust.json" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name allow --policy-document "file://${WORK}/allow.json"

CREDS="$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name sns-sub --output json)"
AK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
SK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
ST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"

SUB_ARN="$(as_role sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
	--notification-endpoint "$INTAKE_ARN" --query SubscriptionArn --output text)"
[[ -n "$SUB_ARN" && "$SUB_ARN" != "None" && "$SUB_ARN" != "pending confirmation" ]] \
	|| { echo "FAIL: intake-queue subscribe returned ${SUB_ARN}" >&2; exit 1; }
echo "OK: Subscribe intake-queue over sqs allowed"

set +e
OUT="$(as_role sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
	--notification-endpoint "$OTHER_ARN" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: other-queue subscribe succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|IAM DENY' \
	|| { echo "FAIL: other-queue: $OUT" >&2; exit 1; }
echo "OK: Subscribe other-queue denied"

set +e
OUT="$(as_role sns subscribe --topic-arn "$TOPIC_ARN" --protocol https \
	--notification-endpoint "https://example.invalid/hook" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: https subscribe succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|IAM DENY' \
	|| { echo "FAIL: https: $OUT" >&2; exit 1; }
echo "OK: Subscribe protocol https denied"
