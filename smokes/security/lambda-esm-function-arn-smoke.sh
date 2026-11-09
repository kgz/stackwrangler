#!/usr/bin/env bash
# Update/DeleteEventSourceMapping honour lambda:FunctionArn from the mapping (#650).
# Happy: Allow on event-source-mapping:* + ArnLike FunctionArn for FN_OK allows
# update/delete of that function's mapping.
# Sad: same policy denies update/delete of FN_OTHER's mapping.
# Depends on #649 mapping-ARN resource shape.
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
P="awsbox-esm-fnarn-${TS}"
FN_OK="${P}-ok"
FN_OTHER="${P}-other"
QUEUE_OK="${P}-q-ok"
QUEUE_OTHER="${P}-q-other"
LAMBDA_ROLE="${P}-lrole"
CALLER="${P}-caller"
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
KEEP="${AWSBOX_ESM_FUNCTION_ARN_KEEP:-0}"
TMP="$(mktemp -d)"
UUID_OK=""
UUID_OTHER=""
QURL_OK=""
QURL_OTHER=""

ESM_MUTATE='["lambda:UpdateEventSourceMapping","lambda:DeleteEventSourceMapping"]'

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	for u in "$UUID_OK" "$UUID_OTHER"; do
		[[ -n "$u" ]] && aws lambda delete-event-source-mapping --uuid "$u" >/dev/null 2>&1 || true
	done
	for fn in "$FN_OK" "$FN_OTHER"; do
		aws lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
	done
	for q in "$QURL_OK" "$QURL_OTHER"; do
		[[ -n "$q" ]] && aws sqs delete-queue --queue-url "$q" >/dev/null 2>&1 || true
	done
	for role in "$CALLER" "$LAMBDA_ROLE"; do
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

expect_deny() {
	local label="$1"
	shift
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
	echo "OK: ${label}"
}

as_role() {
	local role="$1"
	local creds
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	creds="$(aws sts assume-role --role-arn "arn:aws:iam::${ACCT}:role/${role}" --role-session-name esm-fnarn --output json)"
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

wait_active() {
	local fn="$1" state=""
	for _ in $(seq 1 60); do
		state="$(aws lambda get-function --function-name "$fn" --query Configuration.State --output text 2>/dev/null || echo Pending)"
		[[ "$state" == "Active" ]] && return 0
		sleep 2
	done
	echo "FAIL: ${fn} never Active (state=${state})" >&2
	exit 1
}

make_queue() {
	local name="$1"
	aws sqs create-queue --queue-name "$name" \
		--attributes '{"VisibilityTimeout":"30"}' \
		--query QueueUrl --output text
}

QURL_OK="$(make_queue "$QUEUE_OK")"
QURL_OTHER="$(make_queue "$QUEUE_OTHER")"
QARN_OK="$(aws sqs get-queue-attributes --queue-url "$QURL_OK" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
QARN_OTHER="$(aws sqs get-queue-attributes --queue-url "$QURL_OTHER" --attribute-names QueueArn --query Attributes.QueueArn --output text)"

for fn in "$FN_OK" "$FN_OTHER"; do
	aws lambda create-function --function-name "$fn" --runtime nodejs18.x --role "$LARN" \
		--handler index.handler --zip-file "fileb://${TMP}/fn.zip" --timeout 10 >/dev/null
	wait_active "$fn"
done

UUID_OK="$(aws lambda create-event-source-mapping --function-name "$FN_OK" \
	--event-source-arn "$QARN_OK" --batch-size 1 --query UUID --output text)"
UUID_OTHER="$(aws lambda create-event-source-mapping --function-name "$FN_OTHER" \
	--event-source-arn "$QARN_OTHER" --batch-size 1 --query UUID --output text)"

FN_OK_ARN="arn:aws:lambda:${REGION}:${ACCT}:function:${FN_OK}"
MAPPING_RESOURCE="arn:aws:lambda:${REGION}:${ACCT}:event-source-mapping:*"

aws iam create-role --role-name "$CALLER" --assume-role-policy-document "$AT" >/dev/null
aws iam put-role-policy --role-name "$CALLER" --policy-name p --policy-document \
	"{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":${ESM_MUTATE},\"Resource\":\"${MAPPING_RESOURCE}\",\"Condition\":{\"ArnLike\":{\"lambda:FunctionArn\":\"${FN_OK_ARN}\"}}}]}" \
	>/dev/null

as_role "$CALLER"
expect_allow "UpdateEventSourceMapping for matching FunctionArn" \
	aws lambda update-event-source-mapping --uuid "$UUID_OK" --batch-size 5
expect_deny "UpdateEventSourceMapping for other function denied" \
	aws lambda update-event-source-mapping --uuid "$UUID_OTHER" --batch-size 5
expect_deny "DeleteEventSourceMapping for other function denied" \
	aws lambda delete-event-source-mapping --uuid "$UUID_OTHER"
expect_allow "DeleteEventSourceMapping for matching FunctionArn" \
	aws lambda delete-event-source-mapping --uuid "$UUID_OK"
UUID_OK=""

echo "lambda-esm-function-arn-smoke: PASS"
