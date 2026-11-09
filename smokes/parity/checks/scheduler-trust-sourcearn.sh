#!/usr/bin/env bash
# Dual-target: Scheduler AssumeRole SourceAccount / SourceArn (#665).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
GROUP="sw-parity-sch-src-grp-${TS}"
REGION="$PARITY_REGION"
ACCOUNT="$PARITY_ACCOUNT"
FAILS=0
ROLES=()
QUEUES=()
SCHEDULES=()

# Reverse: schedules → group → queues → role policies → roles.
# make_queue/make_role must run in-process (not $(…) / < <()) so arrays populate.
on_cleanup 'for r in "${ROLES[@]:-}"; do [[ -n "$r" ]] && aws iam delete-role --role-name "$r"; done'
on_cleanup 'for r in "${ROLES[@]:-}"; do [[ -n "$r" ]] && aws iam delete-role-policy --role-name "$r" --policy-name send-sqs; done'
on_cleanup 'for q in "${QUEUES[@]:-}"; do [[ -n "$q" ]] && aws sqs delete-queue --queue-url "$q"; done'
on_cleanup "aws scheduler delete-schedule-group --name '$GROUP'"
on_cleanup 'for s in "${SCHEDULES[@]:-}"; do [[ -n "$s" ]] && aws scheduler delete-schedule --name "$s" --group-name "$GROUP"; done'

check() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

OTHER_ACCOUNT="${ACCOUNT:0:11}$(((${ACCOUNT:11:1} + 1) % 10))"
[[ "$OTHER_ACCOUNT" != "$ACCOUNT" ]] || parity_die "cannot derive distinct account from ${ACCOUNT}"

GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCOUNT}:schedule-group/${GROUP}"
WRONG_GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCOUNT}:schedule-group/${GROUP}-nope"

aws scheduler create-schedule-group --name "$GROUP" >/dev/null

MAKE_QUEUE_URL=""
MAKE_QUEUE_ARN=""
MAKE_ROLE_ARN=""

make_queue() {
	local name="$1" url arn
	url="$(aws sqs create-queue --queue-name "$name" --query 'QueueUrl' --output text)"
	[[ -n "$url" && "$url" != "None" ]] || parity_die "CreateQueue ${name}"
	QUEUES+=("$url")
	arn="$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn \
		--query 'Attributes.QueueArn' --output text)"
	MAKE_QUEUE_URL="$url"
	MAKE_QUEUE_ARN="$arn"
}

make_role() {
	local name="$1" trust="$2" qarn="$3"
	aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
	ROLES+=("$name")
	local pol
	pol="$(python3 -c "import json; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:SendMessage','Resource':'$qarn'}]}))")"
	aws iam put-role-policy --role-name "$name" --policy-name send-sqs --policy-document "$pol" >/dev/null
	parity_wait_iam 10
	MAKE_ROLE_ARN="$(aws iam get-role --role-name "$name" --query 'Role.Arn' --output text)"
}

trust_source_account() {
	printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"%s"}}}]}' "$1"
}

trust_source_arn() {
	printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"ArnLike":{"aws:SourceArn":"%s"}}}]}' "$1"
}

fire_once() {
	local sched="$1" role_arn="$2" qarn="$3" body="$4" dlq_arn="${5:-}"
	local at target
	SCHEDULES+=("$sched")
	at="$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%S"))')"
	target="$(
		QARN="$qarn" ROLE_ARN="$role_arn" BODY="$body" DLQ_ARN="$dlq_arn" python3 -c '
import json, os
t = {
	"Arn": os.environ["QARN"],
	"RoleArn": os.environ["ROLE_ARN"],
	"Input": json.dumps({"probe": os.environ["BODY"]}),
	"RetryPolicy": {"MaximumRetryAttempts": 0},
}
dlq = os.environ.get("DLQ_ARN") or ""
if dlq:
	t["DeadLetterConfig"] = {"Arn": dlq}
print(json.dumps(t))
'
	)"
	local i out rc
	for i in $(seq 1 8); do
		set +e
		out="$(aws scheduler create-schedule \
			--name "$sched" \
			--group-name "$GROUP" \
			--schedule-expression "at(${at})" \
			--flexible-time-window Mode=OFF \
			--target "$target" \
			--action-after-completion DELETE 2>&1)"
		rc=$?
		set -e
		[[ "$rc" -eq 0 ]] && {
			echo "$at"
			return 0
		}
		if echo "$out" | grep -qi 'must allow AWS EventBridge Scheduler to assume'; then
			echo "NOTE: Scheduler trust not visible yet for ${sched}; retry…" >&2
			sleep 5
			continue
		fi
		echo "$out" >&2
		parity_die "CreateSchedule ${sched} failed"
	done
	parity_die "CreateSchedule ${sched} failed after IAM retries"
}

wait_body() {
	local queue_url="$1" body="$2" label="$3" at="$4"
	local recv=""
	echo "waiting for ${label} at(${at})…"
	for _ in $(seq 1 40); do
		recv="$(
			aws sqs receive-message \
				--queue-url "$queue_url" \
				--max-number-of-messages 1 \
				--wait-time-seconds 1 \
				--message-attribute-names All \
				--output json
		)"
		echo "$recv" | grep -q "$body" && {
			echo "ok: ${label}"
			printf '%s\n' "$recv"
			return 0
		}
		sleep 1
	done
	check "${label}: no message with probe=${body} after at(${at})"
	printf '%s\n' "$recv"
	return 1
}

make_queue "sw-parity-sch-src-acct-${TS}"
Q_ACCT_URL="$MAKE_QUEUE_URL"
Q_ACCT_ARN="$MAKE_QUEUE_ARN"
ROLE_ACCT="sw-parity-sch-src-acct-role-${TS}"
make_role "$ROLE_ACCT" "$(trust_source_account "$ACCOUNT")" "$Q_ACCT_ARN"
ROLE_ACCT_ARN="$MAKE_ROLE_ARN"
BODY_ACCT="srcacct-${TS}"
AT_ACCT="$(fire_once "sw-parity-sch-src-acct-${TS}" "$ROLE_ACCT_ARN" "$Q_ACCT_ARN" "$BODY_ACCT")"
wait_body "$Q_ACCT_URL" "$BODY_ACCT" "aws:SourceAccount match" "$AT_ACCT" >/dev/null || true

make_queue "sw-parity-sch-src-arn-${TS}"
Q_ARN_URL="$MAKE_QUEUE_URL"
Q_ARN_ARN="$MAKE_QUEUE_ARN"
ROLE_ARN_NAME="sw-parity-sch-src-arn-role-${TS}"
make_role "$ROLE_ARN_NAME" "$(trust_source_arn "$GROUP_ARN")" "$Q_ARN_ARN"
ROLE_ARN_ARN="$MAKE_ROLE_ARN"
BODY_ARN="srcarn-${TS}"
AT_ARN="$(fire_once "sw-parity-sch-src-arn-${TS}" "$ROLE_ARN_ARN" "$Q_ARN_ARN" "$BODY_ARN")"
wait_body "$Q_ARN_URL" "$BODY_ARN" "aws:SourceArn schedule-group match" "$AT_ARN" >/dev/null || true

# Real AWS validates AssumeRole at CreateSchedule time — mismatched SourceAccount /
# SourceArn trusts are refused up front (no schedule, no DLQ path).
# LocalEmu allows create and routes the failed invoke to the DLQ.
expect_create_refused() {
	local sched="$1" role_arn="$2" qarn="$3" label="$4"
	local at target out rc
	at="$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%S"))')"
	target="$(
		QARN="$qarn" ROLE_ARN="$role_arn" BODY="probe" python3 -c '
import json, os
print(json.dumps({
	"Arn": os.environ["QARN"],
	"RoleArn": os.environ["ROLE_ARN"],
	"Input": json.dumps({"probe": os.environ["BODY"]}),
	"RetryPolicy": {"MaximumRetryAttempts": 0},
}))
'
	)"
	set +e
	out="$(aws scheduler create-schedule \
		--name "$sched" \
		--group-name "$GROUP" \
		--schedule-expression "at(${at})" \
		--flexible-time-window Mode=OFF \
		--target "$target" \
		--action-after-completion DELETE 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || {
		SCHEDULES+=("$sched")
		check "${label}: CreateSchedule succeeded"
		return 1
	}
	echo "$out" | grep -qiE 'must allow AWS EventBridge Scheduler to assume|ValidationException|AccessDenied|not authorized' \
		|| {
			check "${label}: unexpected CreateSchedule error: ${out}"
			return 1
		}
	parity_pass "${label}: CreateSchedule refused"
}

make_queue "sw-parity-sch-src-badacct-${TS}"
Q_BAD_ACCT_URL="$MAKE_QUEUE_URL"
Q_BAD_ACCT_ARN="$MAKE_QUEUE_ARN"
ROLE_BAD_ACCT="sw-parity-sch-src-badacct-role-${TS}"
make_role "$ROLE_BAD_ACCT" "$(trust_source_account "$OTHER_ACCOUNT")" "$Q_BAD_ACCT_ARN"
ROLE_BAD_ACCT_ARN="$MAKE_ROLE_ARN"
BODY_BAD_ACCT="badacct-${TS}"
if [[ "$PARITY_TARGET" == "real" ]]; then
	expect_create_refused "sw-parity-sch-src-badacct-${TS}" "$ROLE_BAD_ACCT_ARN" "$Q_BAD_ACCT_ARN" "wrong SourceAccount"
else
	make_queue "sw-parity-sch-src-badacct-dlq-${TS}"
	DLQ_ACCT_URL="$MAKE_QUEUE_URL"
	DLQ_ACCT_ARN="$MAKE_QUEUE_ARN"
	AT_BAD_ACCT="$(fire_once "sw-parity-sch-src-badacct-${TS}" "$ROLE_BAD_ACCT_ARN" "$Q_BAD_ACCT_ARN" "$BODY_BAD_ACCT" "$DLQ_ACCT_ARN")"
	DLQ_ACCT_MSG="$(wait_body "$DLQ_ACCT_URL" "$BODY_BAD_ACCT" "wrong SourceAccount → DLQ" "$AT_BAD_ACCT")" || true
	if echo "$DLQ_ACCT_MSG" | grep -q "$BODY_BAD_ACCT"; then
		leak="$(aws sqs receive-message --queue-url "$Q_BAD_ACCT_URL" --max-number-of-messages 1 --wait-time-seconds 1 --output json || true)"
		if echo "$leak" | grep -q "$BODY_BAD_ACCT"; then
			check "wrong SourceAccount delivered to target queue"
		fi
		if ! echo "$DLQ_ACCT_MSG" | grep -q 'scheduler.amazonaws.com'; then
			check "wrong SourceAccount DLQ ERROR_MESSAGE should name scheduler.amazonaws.com (not root)"
		fi
	fi
fi

make_queue "sw-parity-sch-src-badarn-${TS}"
Q_BAD_ARN_URL="$MAKE_QUEUE_URL"
Q_BAD_ARN_ARN="$MAKE_QUEUE_ARN"
ROLE_BAD_ARN="sw-parity-sch-src-badarn-role-${TS}"
make_role "$ROLE_BAD_ARN" "$(trust_source_arn "$WRONG_GROUP_ARN")" "$Q_BAD_ARN_ARN"
ROLE_BAD_ARN_ARN="$MAKE_ROLE_ARN"
BODY_BAD_ARN="badarn-${TS}"
if [[ "$PARITY_TARGET" == "real" ]]; then
	expect_create_refused "sw-parity-sch-src-badarn-${TS}" "$ROLE_BAD_ARN_ARN" "$Q_BAD_ARN_ARN" "wrong SourceArn"
else
	make_queue "sw-parity-sch-src-badarn-dlq-${TS}"
	DLQ_ARN_URL="$MAKE_QUEUE_URL"
	DLQ_ARN_ARN="$MAKE_QUEUE_ARN"
	AT_BAD_ARN="$(fire_once "sw-parity-sch-src-badarn-${TS}" "$ROLE_BAD_ARN_ARN" "$Q_BAD_ARN_ARN" "$BODY_BAD_ARN" "$DLQ_ARN_ARN")"
	DLQ_ARN_MSG="$(wait_body "$DLQ_ARN_URL" "$BODY_BAD_ARN" "wrong SourceArn group → DLQ" "$AT_BAD_ARN")" || true
	if echo "$DLQ_ARN_MSG" | grep -q "$BODY_BAD_ARN"; then
		leak="$(aws sqs receive-message --queue-url "$Q_BAD_ARN_URL" --max-number-of-messages 1 --wait-time-seconds 1 --output json || true)"
		if echo "$leak" | grep -q "$BODY_BAD_ARN"; then
			check "wrong SourceArn delivered to target queue"
		fi
		if ! echo "$DLQ_ARN_MSG" | grep -q 'scheduler.amazonaws.com'; then
			check "wrong SourceArn DLQ ERROR_MESSAGE should name scheduler.amazonaws.com (not root)"
		fi
	fi
fi

((FAILS == 0)) || exit 1
parity_pass "scheduler-trust-sourcearn"
parity_finish
