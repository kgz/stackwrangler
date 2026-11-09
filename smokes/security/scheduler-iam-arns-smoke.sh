#!/usr/bin/env bash
# Scheduler IAM resource ARNs use schedule-group/<name> and schedule/<group>/<name> (#663).
# Happy: role scoped to one group can create/get/delete that group and its schedules.
# Sad: same role is denied on another group; AccessDenied cites schedule-group/<name>.
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
ACCT="000000000000"
P="awsbox-sched-arn-${TS}"
ALLOW_GROUP="${P}-ok"
DENY_GROUP="${P}-no"
SCHED_NAME="${P}-sched"
QUEUE="${P}-q"
TARGET_ROLE="${P}-target"
CALLER="${P}-caller"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
KEEP="${AWSBOX_SCHEDULER_IAM_ARNS_KEEP:-0}"
QURL=""
CREATED_ALLOW_GROUP=0
CREATED_SCHED=0

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	[[ "$CREATED_SCHED" -eq 1 ]] && aws scheduler delete-schedule --name "$SCHED_NAME" --group-name "$ALLOW_GROUP" >/dev/null 2>&1 || true
	[[ "$CREATED_ALLOW_GROUP" -eq 1 ]] && aws scheduler delete-schedule-group --name "$ALLOW_GROUP" >/dev/null 2>&1 || true
	aws scheduler delete-schedule-group --name "$DENY_GROUP" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	for role in "$CALLER" "$TARGET_ROLE"; do
		aws iam delete-role-policy --role-name "$role" --policy-name p >/dev/null 2>&1 || true
		aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

expect_allow() {
	local label="$1"
	shift
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || {
		echo "FAIL: ${label} denied/failed: ${out}" >&2
		exit 1
	}
	echo "OK: ${label}"
}

expect_deny_resource() {
	local label="$1"
	local resource_arn="$2"
	shift 2
	local out rc
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || {
		echo "FAIL: ${label} succeeded" >&2
		echo "$out" >&2
		exit 1
	}
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny' <<<"$out" \
		|| {
			echo "FAIL: ${label}: ${out}" >&2
			exit 1
		}
	grep -q "$resource_arn" <<<"$out" \
		|| {
			echo "FAIL: ${label}: AccessDenied missing '${resource_arn}': ${out}" >&2
			exit 1
		}
	# Wrong shape from the generic Name fallback (pre-#663).
	grep -qE "arn:aws:scheduler:${REGION}:${ACCT}:${DENY_GROUP}\$" <<<"$out" \
		&& {
			echo "FAIL: ${label}: AccessDenied still cites bare Name ARN: ${out}" >&2
			exit 1
		}
	echo "OK: ${label}"
}

as_role() {
	local role="$1"
	local creds
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	creds="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${role}" --role-session-name sched-arn --output json)"
	AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

AT='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'"$ACCT"':root"},"Action":"sts:AssumeRole"}]}'
ST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

QURL="$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

aws iam create-role --role-name "$TARGET_ROLE" --assume-role-policy-document "$ST" >/dev/null
aws iam put-role-policy --role-name "$TARGET_ROLE" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"${QARN}\"}]}" \
	>/dev/null
TARGET_ROLE_ARN="$(aws iam get-role --role-name "$TARGET_ROLE" --query Role.Arn --output text)"

ALLOW_GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCT}:schedule-group/${ALLOW_GROUP}"
ALLOW_SCHED_ARN="arn:aws:scheduler:${REGION}:${ACCT}:schedule/${ALLOW_GROUP}/*"
DENY_GROUP_ARN="arn:aws:scheduler:${REGION}:${ACCT}:schedule-group/${DENY_GROUP}"

aws iam create-role --role-name "$CALLER" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$CALLER" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[
		{\"Effect\":\"Allow\",\"Action\":[\"scheduler:CreateScheduleGroup\",\"scheduler:GetScheduleGroup\",\"scheduler:DeleteScheduleGroup\"],\"Resource\":\"${ALLOW_GROUP_ARN}\"},
		{\"Effect\":\"Allow\",\"Action\":[\"scheduler:CreateSchedule\",\"scheduler:GetSchedule\",\"scheduler:DeleteSchedule\"],\"Resource\":\"${ALLOW_SCHED_ARN}\"},
		{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"${TARGET_ROLE_ARN}\"}
	]}" \
	>/dev/null

as_role "$CALLER"

expect_deny_resource "CreateScheduleGroup other group denied" "$DENY_GROUP_ARN" \
	aws scheduler create-schedule-group --name "$DENY_GROUP"

expect_allow "CreateScheduleGroup scoped group" \
	aws scheduler create-schedule-group --name "$ALLOW_GROUP"
CREATED_ALLOW_GROUP=1

expect_allow "GetScheduleGroup scoped group" \
	aws scheduler get-schedule-group --name "$ALLOW_GROUP"

EXPR="at($(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v+2H +%Y-%m-%dT%H:%M:%S))"
TARGET="{\"Arn\":\"${QARN}\",\"RoleArn\":\"${TARGET_ROLE_ARN}\"}"
expect_allow "CreateSchedule in scoped group" \
	aws scheduler create-schedule \
		--name "$SCHED_NAME" \
		--group-name "$ALLOW_GROUP" \
		--schedule-expression "$EXPR" \
		--flexible-time-window '{"Mode":"OFF"}' \
		--target "$TARGET"
CREATED_SCHED=1

expect_allow "GetSchedule in scoped group" \
	aws scheduler get-schedule --name "$SCHED_NAME" --group-name "$ALLOW_GROUP"

expect_allow "DeleteSchedule in scoped group" \
	aws scheduler delete-schedule --name "$SCHED_NAME" --group-name "$ALLOW_GROUP"
CREATED_SCHED=0

expect_allow "DeleteScheduleGroup scoped group" \
	aws scheduler delete-schedule-group --name "$ALLOW_GROUP"
CREATED_ALLOW_GROUP=0

echo "scheduler-iam-arns-smoke: PASS"
