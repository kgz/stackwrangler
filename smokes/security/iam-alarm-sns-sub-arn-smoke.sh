#!/usr/bin/env bash
# CloudWatch AlarmNames + SNS SubscriptionArn IAM resources (#651).
# Happy: scoped Allow on alarm:<name> and <topicArn>:* permits describe/delete
#        alarms and get/set/unsubscribe subscription.
# Sad: Allow on a different alarm / topic still denies; AccessDenied cites the
#      concrete alarm ARN / subscription ARN (not account:*).
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
P="awsbox-cw-sns-arn-${TS}"
ALARM_A="${P}-a"
ALARM_B="${P}-b"
TOPIC="${P}-topic"
QUEUE="${P}-q"
CALLER="${P}-ok"
WRONG="${P}-wrong"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
KEEP="${AWSBOX_ALARM_SNS_ARN_KEEP:-0}"
TOPIC_ARN=""
SUB_ARN=""
QURL=""

CW_ACTIONS='["cloudwatch:DescribeAlarms","cloudwatch:DeleteAlarms","cloudwatch:PutMetricAlarm"]'
SNS_ACTIONS='["sns:Unsubscribe","sns:GetSubscriptionAttributes","sns:SetSubscriptionAttributes","sns:Subscribe","sns:CreateTopic"]'

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	aws cloudwatch delete-alarms --alarm-names "$ALARM_A" "$ALARM_B" >/dev/null 2>&1 || true
	[[ -n "$SUB_ARN" ]] && aws sns unsubscribe --subscription-arn "$SUB_ARN" >/dev/null 2>&1 || true
	[[ -n "$TOPIC_ARN" ]] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	for role in "$CALLER" "$WRONG"; do
		[[ -z "$role" ]] && continue
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

expect_deny_arn() {
	local label="$1"
	local arn_needle="$2"
	local star_needle="$3"
	shift 3
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
	grep -Fq "$arn_needle" <<<"$out" \
		|| {
			echo "FAIL: ${label}: AccessDenied missing '${arn_needle}': ${out}" >&2
			exit 1
		}
	# Fixed-string: a regex '*' would match alarm:<name> / topic:sub-id.
	grep -Fq "$star_needle" <<<"$out" \
		&& {
			echo "FAIL: ${label}: AccessDenied still cites '${star_needle}': ${out}" >&2
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
	creds="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${role}" --role-session-name cw-sns-arn --output json)"
	AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

AT='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'"$ACCT"':root"},"Action":"sts:AssumeRole"}]}'

# Fixtures as admin.
aws cloudwatch put-metric-alarm --alarm-name "$ALARM_A" \
	--metric-name CPUUtilization --namespace AWS/EC2 --statistic Average \
	--period 60 --evaluation-periods 1 --threshold 80 \
	--comparison-operator GreaterThanThreshold >/dev/null
aws cloudwatch put-metric-alarm --alarm-name "$ALARM_B" \
	--metric-name CPUUtilization --namespace AWS/EC2 --statistic Average \
	--period 60 --evaluation-periods 1 --threshold 90 \
	--comparison-operator GreaterThanThreshold >/dev/null
ALARM_A_ARN="arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:${ALARM_A}"
ALARM_B_ARN="arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:${ALARM_B}"
CW_STAR="arn:aws:cloudwatch:${REGION}:${ACCT}:*"

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)"
QURL="$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
# Delivery policy is irrelevant here — we only need a SubscriptionArn for IAM.
SUB_ARN="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
	--notification-endpoint "$QARN" --query SubscriptionArn --output text)"
[[ "$SUB_ARN" == arn:aws:sns:* ]] || {
	echo "FAIL: subscribe returned '${SUB_ARN}'" >&2
	exit 1
}
SNS_STAR="arn:aws:sns:${REGION}:${ACCT}:*"

aws iam create-role --role-name "$CALLER" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$CALLER" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[
		{\"Effect\":\"Allow\",\"Action\":${CW_ACTIONS},\"Resource\":\"${ALARM_A_ARN}\"},
		{\"Effect\":\"Allow\",\"Action\":${SNS_ACTIONS},\"Resource\":[\"${TOPIC_ARN}\",\"${TOPIC_ARN}:*\"]}
	]}" >/dev/null

aws iam create-role --role-name "$WRONG" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$WRONG" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[
		{\"Effect\":\"Allow\",\"Action\":${CW_ACTIONS},\"Resource\":\"${ALARM_B_ARN}\"},
		{\"Effect\":\"Allow\",\"Action\":${SNS_ACTIONS},\"Resource\":\"arn:aws:sns:${REGION}:${ACCT}:other-topic\"}
	]}" >/dev/null

as_role "$WRONG"
expect_deny_arn "DescribeAlarms wrong alarm denied" "$ALARM_A_ARN" "$CW_STAR" \
	aws cloudwatch describe-alarms --alarm-names "$ALARM_A"
expect_deny_arn "DeleteAlarms wrong alarm denied" "$ALARM_A_ARN" "$CW_STAR" \
	aws cloudwatch delete-alarms --alarm-names "$ALARM_A"
expect_deny_arn "GetSubscriptionAttributes wrong topic denied" "$SUB_ARN" "$SNS_STAR" \
	aws sns get-subscription-attributes --subscription-arn "$SUB_ARN"
expect_deny_arn "SetSubscriptionAttributes wrong topic denied" "$SUB_ARN" "$SNS_STAR" \
	aws sns set-subscription-attributes --subscription-arn "$SUB_ARN" \
	--attribute-name RawMessageDelivery --attribute-value true
expect_deny_arn "Unsubscribe wrong topic denied" "$SUB_ARN" "$SNS_STAR" \
	aws sns unsubscribe --subscription-arn "$SUB_ARN"

as_role "$CALLER"
expect_allow "DescribeAlarms via alarm Allow" \
	aws cloudwatch describe-alarms --alarm-names "$ALARM_A"
# Multi-name: every named alarm must be allowed — ALARM_B is out of scope.
expect_deny_arn "DescribeAlarms multi-name denies missing alarm" "$ALARM_B_ARN" "$CW_STAR" \
	aws cloudwatch describe-alarms --alarm-names "$ALARM_A" "$ALARM_B"
expect_allow "GetSubscriptionAttributes via topic:* Allow" \
	aws sns get-subscription-attributes --subscription-arn "$SUB_ARN"
expect_allow "SetSubscriptionAttributes via topic:* Allow" \
	aws sns set-subscription-attributes --subscription-arn "$SUB_ARN" \
	--attribute-name RawMessageDelivery --attribute-value true
expect_allow "Unsubscribe via topic:* Allow" \
	aws sns unsubscribe --subscription-arn "$SUB_ARN"
SUB_ARN=""
expect_allow "DeleteAlarms via alarm Allow" \
	aws cloudwatch delete-alarms --alarm-names "$ALARM_A"

echo "iam-alarm-sns-sub-arn-smoke: PASS"
