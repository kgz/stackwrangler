#!/usr/bin/env bash
# Get/Update/DeleteEventSourceMapping authorise against event-source-mapping:<UUID> (#649).
# Happy: policy on event-source-mapping:* allows get/update/delete.
# Sad: policy on function:* still denies; AccessDenied cites the mapping ARN (not function:*).
# Resource ARN only; FunctionArn condition is `lambda-esm-function-arn-smoke.sh` (#650).
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
P="awsbox-esm-arn-${TS}"
FN="${P}-fn"
QUEUE="${P}-q"
LAMBDA_ROLE="${P}-lrole"
CALLER="${P}-ok"
WRONG="${P}-fnstar"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
KEEP="${AWSBOX_ESM_MAPPING_ARN_KEEP:-0}"
TMP="$(mktemp -d)"
UUID=""
QURL=""

ESM_ACTIONS='["lambda:GetEventSourceMapping","lambda:UpdateEventSourceMapping","lambda:DeleteEventSourceMapping"]'

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	[[ -n "$UUID" ]] && aws lambda delete-event-source-mapping --uuid "$UUID" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	for role in "$CALLER" "$WRONG" "$LAMBDA_ROLE"; do
		[[ -z "$role" ]] && continue
		aws iam delete-role-policy --role-name "$role" --policy-name p >/dev/null 2>&1 || true
		aws iam delete-role-policy --role-name "$role" --policy-name inline >/dev/null 2>&1 || true
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

expect_deny_mapping_arn() {
	local label="$1"
	local mapping_arn="$2"
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
	grep -q "$mapping_arn" <<<"$out" \
		|| {
			echo "FAIL: ${label}: AccessDenied missing mapping ARN '${mapping_arn}': ${out}" >&2
			exit 1
		}
	grep -q 'function:\*' <<<"$out" \
		&& {
			echo "FAIL: ${label}: AccessDenied still cites function:*: ${out}" >&2
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
	creds="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${role}" --role-session-name esm-arn --output json)"
	AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

python3 - "$TMP" <<'PY'
import sys, zipfile
path = f"{sys.argv[1]}/fn.zip"
code = b"exports.handler = async () => ({ ok: true });\n"
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

LT='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
AT='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'"$ACCT"':root"},"Action":"sts:AssumeRole"}]}'

aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document "$LT" >/dev/null
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name inline --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","logs:*"],"Resource":"*"}]}'
LARN="$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)"

QURL="$(aws sqs create-queue --queue-name "$QUEUE" \
	--attributes '{"VisibilityTimeout":"30"}' \
	--query QueueUrl --output text)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

aws lambda create-function --function-name "$FN" --runtime nodejs18.x --role "$LARN" \
	--handler index.handler --zip-file "fileb://${TMP}/fn.zip" --timeout 10 >/dev/null
state=""
for _ in $(seq 1 60); do
	state="$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text 2>/dev/null || echo Pending)"
	[[ "$state" == "Active" ]] && break
	sleep 2
done
[[ "$state" == "Active" ]] || {
	echo "FAIL: function never Active (state=${state})" >&2
	exit 1
}

UUID="$(aws lambda create-event-source-mapping --function-name "$FN" \
	--event-source-arn "$QARN" --batch-size 1 --query UUID --output text)"
MAPPING_ARN="arn:aws:lambda:${REGION}:${ACCT}:event-source-mapping:${UUID}"

aws iam create-role --role-name "$CALLER" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$CALLER" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":${ESM_ACTIONS},\"Resource\":\"arn:aws:lambda:${REGION}:${ACCT}:event-source-mapping:*\"}]}" \
	>/dev/null

aws iam create-role --role-name "$WRONG" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$WRONG" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":${ESM_ACTIONS},\"Resource\":\"arn:aws:lambda:${REGION}:${ACCT}:function:*\"}]}" \
	>/dev/null

as_role "$WRONG"
expect_deny_mapping_arn "GetEventSourceMapping via function:* denied" "$MAPPING_ARN" \
	aws lambda get-event-source-mapping --uuid "$UUID"
expect_deny_mapping_arn "UpdateEventSourceMapping via function:* denied" "$MAPPING_ARN" \
	aws lambda update-event-source-mapping --uuid "$UUID" --no-enabled
expect_deny_mapping_arn "DeleteEventSourceMapping via function:* denied" "$MAPPING_ARN" \
	aws lambda delete-event-source-mapping --uuid "$UUID"

as_role "$CALLER"
expect_allow "GetEventSourceMapping via mapping Allow" \
	aws lambda get-event-source-mapping --uuid "$UUID"
expect_allow "UpdateEventSourceMapping via mapping Allow" \
	aws lambda update-event-source-mapping --uuid "$UUID" --no-enabled
expect_allow "DeleteEventSourceMapping via mapping Allow" \
	aws lambda delete-event-source-mapping --uuid "$UUID"
UUID=""

echo "lambda-esm-mapping-arn-smoke: PASS"
