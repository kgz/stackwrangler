#!/usr/bin/env bash
# Dual-target: EventBridge Scheduler group + at() → SQS (#662).
# PARITY_TARGET=local|real (set by bin/parity).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
GROUP="sw-parity-sched-grp-${TS}"
SCHED="sw-parity-sched-${TS}"
QNAME="sw-parity-sched-q-${TS}"
ROLE="sw-parity-sched-role-${TS}"
BODY="sw-parity-scheduler-${TS}"
QUEUE_URL=""
WORKDIR="${TMPDIR:-/tmp}/sw-parity-sched-del-$$"
mkdir -p "$WORKDIR"
on_cleanup "rm -rf '$WORKDIR'"

# Reverse order: schedule → group → queue → role-policy → role
on_cleanup "aws iam delete-role --role-name '$ROLE'"
on_cleanup "aws iam delete-role-policy --role-name '$ROLE' --policy-name send-sqs"
on_cleanup '[[ -n "$QUEUE_URL" ]] && aws sqs delete-queue --queue-url "$QUEUE_URL"'
on_cleanup "aws scheduler delete-schedule-group --name '$GROUP'"
on_cleanup "aws scheduler delete-schedule --name '$SCHED' --group-name '$GROUP'"

QUEUE_URL="$(aws sqs create-queue --queue-name "$QNAME" --query 'QueueUrl' --output text)"
[[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]] || parity_die "CreateQueue failed"
QARN="$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn \
	--query 'Attributes.QueueArn' --output text)"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
POL="$(python3 -c "import json; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:SendMessage','Resource':'$QARN'}]}))")"
aws iam put-role-policy --role-name "$ROLE" --policy-name send-sqs --policy-document "$POL" >/dev/null
parity_wait_iam 12

aws scheduler create-schedule-group --name "$GROUP" >/dev/null
aws scheduler get-schedule-group --name "$GROUP" --query 'Name' --output text | grep -qx "$GROUP" \
	|| parity_die "schedule group ${GROUP} missing"

create_sched() {
	local at target
	at="$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(seconds=8)).strftime("%Y-%m-%dT%H:%M:%S"))')"
	target="$(
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
		--schedule-expression "at(${at})" \
		--flexible-time-window Mode=OFF \
		--target "$target" \
		--action-after-completion DELETE >/dev/null
	printf '%s\n' "$at"
}

AT=""
for _ in $(seq 1 8); do
	set +e
	AT="$(create_sched 2>"$WORKDIR/create-sched.err")"
	rc=$?
	set -e
	[[ "$rc" -eq 0 && -n "$AT" ]] && break
	if grep -qi 'must allow AWS EventBridge Scheduler to assume' "$WORKDIR/create-sched.err" 2>/dev/null; then
		echo "NOTE: Scheduler trust not visible yet; retry…"
		sleep 5
		AT=""
		continue
	fi
	cat "$WORKDIR/create-sched.err" >&2 || true
	parity_die "CreateSchedule failed"
done
[[ -n "$AT" ]] || parity_die "CreateSchedule failed after IAM retries"

aws scheduler get-schedule --name "$SCHED" --group-name "$GROUP" \
	--query 'ScheduleExpression' --output text | grep -qx "at(${AT})" \
	|| parity_die "schedule expression mismatch"

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
echo "$recv" | grep -q "$BODY" || parity_die "no SQS message with probe=${BODY} after at(${AT})"

parity_pass "scheduler group + at() → SQS (${GROUP}/${SCHED})"
parity_finish
