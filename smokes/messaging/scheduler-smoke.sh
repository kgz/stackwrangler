#!/usr/bin/env bash
# Happy: EventBridge Scheduler create-schedule-group + one-off at(...) → SQS.
# Confirms SERVICES includes scheduler and target_invoker delivers (#662).
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

TS="$(date +%s)"
GROUP="awsbox-sched-grp-${TS}"
SCHED="awsbox-sched-${TS}"
QNAME="awsbox-sched-q-${TS}"
ROLE="awsbox-sched-role-${TS}"
KEEP="${AWSBOX_SCHEDULER_KEEP:-0}"
QUEUE_URL=""
BODY="awsbox-scheduler-smoke-${TS}"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws scheduler delete-schedule --name "$SCHED" --group-name "$GROUP" >/dev/null 2>&1 || true
	aws scheduler delete-schedule-group --name "$GROUP" >/dev/null 2>&1 || true
	[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name send-sqs >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

QUEUE_URL="$(aws sqs create-queue --queue-name "$QNAME" --query 'QueueUrl' --output text)"
[[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]] || fail "CreateQueue failed"
QARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
	--query 'Attributes.QueueArn' --output text)"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
POL="$(python3 -c "import json; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:SendMessage','Resource':'$QARN'}]}))")"
aws iam put-role-policy --role-name "$ROLE" --policy-name send-sqs --policy-document "$POL" >/dev/null

aws scheduler create-schedule-group --name "$GROUP" >/dev/null
aws scheduler get-schedule-group --name "$GROUP" --query 'Name' --output text | grep -qx "$GROUP" \
	|| fail "schedule group ${GROUP} missing"

# One-shot a few seconds out (UTC); tick loop is 1s.
AT="$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(seconds=8)).strftime("%Y-%m-%dT%H:%M:%S"))')"
TARGET="$(
	QARN="$QARN" ROLE_ARN="$ROLE_ARN" BODY="$BODY" python3 -c '
import json, os
print(json.dumps({
	"Arn": os.environ["QARN"],
	"RoleArn": os.environ["ROLE_ARN"],
	"Input": json.dumps({"probe": os.environ["BODY"]}),
}))
'
)"

aws scheduler create-schedule \
	--name "$SCHED" \
	--group-name "$GROUP" \
	--schedule-expression "at(${AT})" \
	--flexible-time-window Mode=OFF \
	--target "$TARGET" \
	--action-after-completion DELETE >/dev/null

aws scheduler get-schedule --name "$SCHED" --group-name "$GROUP" \
	--query 'ScheduleExpression' --output text | grep -qx "at(${AT})" \
	|| fail "schedule expression mismatch"

echo "waiting for at(${AT}) → SQS…"
recv=""
for _ in $(seq 1 45); do
	recv="$(
		aws sqs receive-message \
			--queue-url "$QUEUE_URL" \
			--max-number-of-messages 1 \
			--wait-time-seconds 1 \
			--output json
	)"
	echo "$recv" | grep -q "$BODY" && break
	sleep 1
done
echo "$recv" | grep -q "$BODY" || fail "no SQS message with probe=${BODY} after at(${AT})"

echo "OK: scheduler group + at() → SQS (${GROUP}/${SCHED})"
