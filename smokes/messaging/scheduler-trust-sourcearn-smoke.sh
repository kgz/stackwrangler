#!/usr/bin/env bash
# Scheduler target RoleArn trust aws:SourceAccount / aws:SourceArn (#665).
# Happy: SourceAccount match and ArnLike on schedule-group → SQS delivery.
# Sad: wrong account / wrong group → DeadLetterConfig SQS (not the target queue).
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
GROUP="awsbox-sch-src-grp-${TS}"
KEEP="${AWSBOX_SCHEDULER_TRUST_KEEP:-0}"
FAILS=0

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
check() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

ROLES=()
QUEUES=()
SCHEDULES=()

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	local s q r
	for s in "${SCHEDULES[@]:-}"; do
		[[ -n "$s" ]] || continue
		aws scheduler delete-schedule --name "$s" --group-name "$GROUP" >/dev/null 2>&1 || true
	done
	aws scheduler delete-schedule-group --name "$GROUP" >/dev/null 2>&1 || true
	for q in "${QUEUES[@]:-}"; do
		[[ -n "$q" ]] || continue
		aws sqs delete-queue --queue-url "$q" >/dev/null 2>&1 || true
	done
	for r in "${ROLES[@]:-}"; do
		[[ -n "$r" ]] || continue
		aws iam delete-role-policy --role-name "$r" --policy-name send-sqs >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [[ ! "$ACCOUNT" =~ ^[0-9]{12}$ ]]; then
	fail "caller account '${ACCOUNT}' is not 12 digits"
fi
OTHER_ACCOUNT="${ACCOUNT:0:11}$(((${ACCOUNT:11:1} + 1) % 10))"
[[ "$OTHER_ACCOUNT" != "$ACCOUNT" ]] || fail "cannot derive distinct account from ${ACCOUNT}"

GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCOUNT}:schedule-group/${GROUP}"
WRONG_GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCOUNT}:schedule-group/${GROUP}-nope"

aws scheduler create-schedule-group --name "$GROUP" >/dev/null

make_queue() {
	local name="$1" url arn
	url="$(aws sqs create-queue --queue-name "$name" --query 'QueueUrl' --output text)"
	[[ -n "$url" && "$url" != "None" ]] || fail "CreateQueue ${name}"
	QUEUES+=("$url")
	arn="$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn \
		--query 'Attributes.QueueArn' --output text)"
	printf '%s\t%s\n' "$url" "$arn"
}

make_role() {
	local name="$1" trust="$2" qarn="$3"
	aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
	ROLES+=("$name")
	local pol
	pol="$(python3 -c "import json; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:SendMessage','Resource':'$qarn'}]}))")"
	aws iam put-role-policy --role-name "$name" --policy-name send-sqs --policy-document "$pol" >/dev/null
	aws iam get-role --role-name "$name" --query 'Role.Arn' --output text
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
	aws scheduler create-schedule \
		--name "$sched" \
		--group-name "$GROUP" \
		--schedule-expression "at(${at})" \
		--flexible-time-window Mode=OFF \
		--target "$target" \
		--action-after-completion DELETE >/dev/null
	echo "$at"
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

# --- happy: SourceAccount ---
IFS=$'\t' read -r Q_ACCT_URL Q_ACCT_ARN < <(make_queue "awsbox-sch-src-acct-${TS}")
ROLE_ACCT="awsbox-sch-src-acct-role-${TS}"
ROLE_ACCT_ARN="$(make_role "$ROLE_ACCT" "$(trust_source_account "$ACCOUNT")" "$Q_ACCT_ARN")"
BODY_ACCT="srcacct-${TS}"
AT_ACCT="$(fire_once "awsbox-sch-src-acct-${TS}" "$ROLE_ACCT_ARN" "$Q_ACCT_ARN" "$BODY_ACCT")"
wait_body "$Q_ACCT_URL" "$BODY_ACCT" "aws:SourceAccount match" "$AT_ACCT" >/dev/null || true

# --- happy: ArnLike schedule-group ---
IFS=$'\t' read -r Q_ARN_URL Q_ARN_ARN < <(make_queue "awsbox-sch-src-arn-${TS}")
ROLE_ARN_NAME="awsbox-sch-src-arn-role-${TS}"
ROLE_ARN_ARN="$(make_role "$ROLE_ARN_NAME" "$(trust_source_arn "$GROUP_ARN")" "$Q_ARN_ARN")"
BODY_ARN="srcarn-${TS}"
AT_ARN="$(fire_once "awsbox-sch-src-arn-${TS}" "$ROLE_ARN_ARN" "$Q_ARN_ARN" "$BODY_ARN")"
wait_body "$Q_ARN_URL" "$BODY_ARN" "aws:SourceArn schedule-group match" "$AT_ARN" >/dev/null || true

# --- sad: wrong SourceAccount → DLQ ---
IFS=$'\t' read -r Q_BAD_ACCT_URL Q_BAD_ACCT_ARN < <(make_queue "awsbox-sch-src-badacct-${TS}")
IFS=$'\t' read -r DLQ_ACCT_URL DLQ_ACCT_ARN < <(make_queue "awsbox-sch-src-badacct-dlq-${TS}")
ROLE_BAD_ACCT="awsbox-sch-src-badacct-role-${TS}"
ROLE_BAD_ACCT_ARN="$(make_role "$ROLE_BAD_ACCT" "$(trust_source_account "$OTHER_ACCOUNT")" "$Q_BAD_ACCT_ARN")"
BODY_BAD_ACCT="badacct-${TS}"
AT_BAD_ACCT="$(fire_once "awsbox-sch-src-badacct-${TS}" "$ROLE_BAD_ACCT_ARN" "$Q_BAD_ACCT_ARN" "$BODY_BAD_ACCT" "$DLQ_ACCT_ARN")"
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

# --- sad: wrong SourceArn group → DLQ ---
IFS=$'\t' read -r Q_BAD_ARN_URL Q_BAD_ARN_ARN < <(make_queue "awsbox-sch-src-badarn-${TS}")
IFS=$'\t' read -r DLQ_ARN_URL DLQ_ARN_ARN < <(make_queue "awsbox-sch-src-badarn-dlq-${TS}")
ROLE_BAD_ARN="awsbox-sch-src-badarn-role-${TS}"
ROLE_BAD_ARN_ARN="$(make_role "$ROLE_BAD_ARN" "$(trust_source_arn "$WRONG_GROUP_ARN")" "$Q_BAD_ARN_ARN")"
BODY_BAD_ARN="badarn-${TS}"
AT_BAD_ARN="$(fire_once "awsbox-sch-src-badarn-${TS}" "$ROLE_BAD_ARN_ARN" "$Q_BAD_ARN_ARN" "$BODY_BAD_ARN" "$DLQ_ARN_ARN")"
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

((FAILS == 0)) || exit 1
echo "scheduler-trust-sourcearn-smoke: PASS"
