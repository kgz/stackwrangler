#!/usr/bin/env bash
# Deploy examples/serverless-v4-sns-sqs as an assumed deploy role (#522).
#
# Happy: --role-arn with Allow * succeeds (topic + consumer).
# Sad: deploy role with logs:DescribeLogGroups scoped to /aws/lambda/*
#   → AccessDenied on describe-log-groups as that principal.
# CFN resource handlers still elevate (#524); stack-event deny is follow-up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v4-sns-sqs"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
if [[ -z "${SERVERLESS_LICENSE_KEY:-}" && -n "${SERVERLESS_LOCAL_ONLY_LICENCE_KEY:-}" ]]; then
	export SERVERLESS_LICENSE_KEY="$SERVERLESS_LOCAL_ONLY_LICENCE_KEY"
fi
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
STAGE="local"
DEPLOY_BUCKET="awsbox-sls4-role-${TS}"
SUFFIX="${TS}"
TOPIC_SERVICE="awsbox-sls4-role-topic-${TS}"
CONSUMER_SERVICE="awsbox-sls4-role-consumer-${TS}"
TOPIC_STACK="${TOPIC_SERVICE}-${STAGE}"
CONSUMER_STACK="${CONSUMER_SERVICE}-${STAGE}"
TOPIC_EXPORT="${TOPIC_SERVICE}-${STAGE}-TopicArn"
GOOD_ROLE="awsbox-sls4-deploy-ok-${TS}"
BAD_ROLE="awsbox-sls4-deploy-bad-${TS}"
OUT="$ROOT/.awsbox/serverless-v4-role-arn-${TS}"
KEEP="${AWSBOX_SLS_V4_KEEP:-0}"
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-300}"
TOPIC_DEPLOYED=0
CONSUMER_DEPLOYED=0
BUCKET_CREATED=0
ROLES_CREATED=0

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWS_ENDPOINT_URL="$EP"
export AWSBOX_SLS4_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLS4_SUFFIX="$SUFFIX"
export AWSBOX_SLS4_TOPIC_SERVICE="$TOPIC_SERVICE"
export AWSBOX_SLS4_CONSUMER_SERVICE="$CONSUMER_SERVICE"
export AWSBOX_SLS4_TOPIC_EXPORT="$TOPIC_EXPORT"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

require_sls_auth() {
	if [[ -n "${SERVERLESS_LICENSE_KEY:-}" || -n "${SERVERLESS_ACCESS_KEY:-}" ]]; then
		return 0
	fi
	echo "error: Serverless Framework v4 needs auth. See docs/serverless-stackwrangler.md" >&2
	exit 1
}

sls_run_timed() {
	local cwd="$1" expect="$2" log="$3"
	shift 3
	local rc=0
	set +e
	timeout --signal=KILL "$SLS_TIMEOUT_SECS" \
		"$ROOT/bin/stackwrangler" sls --cwd "$cwd" "$@" >"$log" 2>&1
	rc=$?
	set -e
	cat "$log"
	if [[ "$rc" -eq 124 ]]; then
		echo "error: sls timed out after ${SLS_TIMEOUT_SECS}s (cwd=${cwd})" >&2
		return 124
	fi
	if [[ "$rc" -ne 0 ]]; then
		return "$rc"
	fi
	if ! grep -qiE "$expect" "$log"; then
		echo "error: sls succeeded but log missing /${expect}/" >&2
		return 1
	fi
	return 0
}

cleanup() {
	set +e
	if [[ "$KEEP" == "1" ]]; then
		echo "KEEP=1 — left stacks/roles under ${OUT}"
		return 0
	fi
	if [[ "$CONSUMER_DEPLOYED" == "1" ]]; then
		"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" -- remove --stage "$STAGE" --verbose \
			>"$OUT/remove-consumer.log" 2>&1 || true
		aws cloudformation delete-stack --stack-name "$CONSUMER_STACK" >/dev/null 2>&1 || true
	fi
	if [[ "$TOPIC_DEPLOYED" == "1" ]]; then
		"$ROOT/bin/stackwrangler" sls --cwd "$EX/topic" -- remove --stage "$STAGE" --verbose \
			>"$OUT/remove-topic.log" 2>&1 || true
		aws cloudformation delete-stack --stack-name "$TOPIC_STACK" >/dev/null 2>&1 || true
	fi
	# Failed sad deploy may leave ROLLBACK_* / CREATE_FAILED.
	aws cloudformation delete-stack --stack-name "$CONSUMER_STACK" >/dev/null 2>&1 || true
	if [[ "$BUCKET_CREATED" == "1" ]]; then
		aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/app-name" >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/topic-arn" >/dev/null 2>&1 || true
	fi
	if [[ "$ROLES_CREATED" == "1" ]]; then
		for r in "$GOOD_ROLE" "$BAD_ROLE"; do
			aws iam delete-role-policy --role-name "$r" --policy-name deploy >/dev/null 2>&1 || true
			aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
		done
	fi
	[[ -d "$OUT" ]] && rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"
require_sls_auth

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/stackwrangler up)" >&2
	exit 1
fi

if [[ ! -d "$EX/node_modules/serverless" ]]; then
	(cd "$EX" && npm install --no-fund --no-audit)
fi

ACCT="$(aws sts get-caller-identity --query Account --output text)"
GOOD_ARN="arn:aws:iam::${ACCT}:role/${GOOD_ROLE}"
BAD_ARN="arn:aws:iam::${ACCT}:role/${BAD_ROLE}"

python3 - "$OUT/trust.json" "$ACCT" <<'PY'
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

# Broad deploy role — exercises IAM as the live principal (admin keys skip it).
python3 - "$OUT/good-policy.json" <<'PY'
import json, sys
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "*",
        "Resource": "*",
    }],
}, open(sys.argv[1], "w"))
PY

# Looks granted on Lambda log groups, but DescribeLogGroups has no resource-level
# perms on AWS — LocalEmu authorizes against log-group:* so /aws/lambda/* never
# matches (same denial you'd hit live). CFN resource handlers still elevate today
# (#524); smoke asserts the API deny under the deploy role.
python3 - "$OUT/bad-policy.json" <<'PY'
import json, sys
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "NotAction": "logs:DescribeLogGroups",
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "logs:DescribeLogGroups",
            "Resource": "arn:aws:logs:*:*:log-group:/aws/lambda/*",
        },
    ],
}, open(sys.argv[1], "w"))
PY

aws iam create-role --role-name "$GOOD_ROLE" --assume-role-policy-document "file://${OUT}/trust.json" >/dev/null
aws iam put-role-policy --role-name "$GOOD_ROLE" --policy-name deploy \
	--policy-document "file://${OUT}/good-policy.json"
aws iam create-role --role-name "$BAD_ROLE" --assume-role-policy-document "file://${OUT}/trust.json" >/dev/null
aws iam put-role-policy --role-name "$BAD_ROLE" --policy-name deploy \
	--policy-document "file://${OUT}/bad-policy.json"
ROLES_CREATED=1

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
BUCKET_CREATED=1
aws ssm put-parameter \
	--name "/demo/sls4/${SUFFIX}/app-name" \
	--type String \
	--value "awsbox-sls4-role-arn" \
	--overwrite >/dev/null

echo "==> happy: topic deploy as --role-arn ${GOOD_ROLE}"
sls_run_timed "$EX/topic" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-topic.log" \
	--role-arn "$GOOD_ARN" --session-name "sls4-role-ok" -- \
	deploy --stage "$STAGE" --verbose
TOPIC_DEPLOYED=1
grep -q "sls: deploying as" "$OUT/deploy-topic.log" || {
	echo "error: missing principal line (sls: deploying as …)" >&2
	exit 1
}
grep -E "sls: deploying as .*${GOOD_ROLE}" "$OUT/deploy-topic.log" || {
	echo "error: principal line did not name ${GOOD_ROLE}" >&2
	exit 1
}
echo "ok   topic deployed as role"

echo "==> happy: consumer deploy as --role-arn ${GOOD_ROLE}"
sls_run_timed "$EX/consumer" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-consumer.log" \
	--role-arn "$GOOD_ARN" --session-name "sls4-role-ok" -- \
	deploy --stage "$STAGE" --verbose
CONSUMER_DEPLOYED=1
echo "ok   consumer deployed as role"

echo "==> --use-session-env: assume-role then package topic"
CREDS="$(aws sts assume-role --role-arn "$GOOD_ARN" --role-session-name sls4-env --output json)"
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$CREDS")"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
sls_run_timed "$EX/topic" 'Service packaged|Packaging service|✔ Service packaged' \
	"$OUT/package-session-env.log" \
	--use-session-env -- \
	package --stage "$STAGE" --verbose
grep -E "sls: deploying as .*${GOOD_ROLE}" "$OUT/package-session-env.log" || {
	echo "error: --use-session-env did not report assumed-role principal" >&2
	exit 1
}
# Restore admin keys for host aws + further sls (admin default / sad assume).
export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
unset AWS_SESSION_TOKEN
echo "ok   --use-session-env"

echo "==> remove consumer (admin) before sad redeploy"
"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" -- remove --stage "$STAGE" --verbose \
	>"$OUT/remove-consumer-pre-sad.log" 2>&1
cat "$OUT/remove-consumer-pre-sad.log"
CONSUMER_DEPLOYED=0
# Wait until gone so sad create is clean.
for _ in $(seq 1 60); do
	st="$(aws cloudformation describe-stacks --stack-name "$CONSUMER_STACK" \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo DELETE_COMPLETE)"
	[[ "$st" == "DELETE_COMPLETE" || "$st" == "None" ]] && break
	# Stack missing → describe fails → we treat as gone via || echo
	if ! aws cloudformation describe-stacks --stack-name "$CONSUMER_STACK" >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

echo "==> sad: scoped DescribeLogGroups as ${BAD_ROLE} → AccessDenied"
BAD_CREDS="$(aws sts assume-role --role-arn "$BAD_ARN" --role-session-name sls4-role-bad-api --output json)"
BAD_AK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$BAD_CREDS")"
BAD_SK="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$BAD_CREDS")"
BAD_ST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$BAD_CREDS")"
set +e
BAD_LOGS_OUT="$(
	AWS_ACCESS_KEY_ID="$BAD_AK" AWS_SECRET_ACCESS_KEY="$BAD_SK" AWS_SESSION_TOKEN="$BAD_ST" \
		aws logs describe-log-groups 2>&1
)"
bad_logs_rc=$?
set -e
printf '%s\n' "$BAD_LOGS_OUT" >"$OUT/sad-describe-log-groups.txt"
cat "$OUT/sad-describe-log-groups.txt"
if [[ "$bad_logs_rc" -eq 0 ]]; then
	echo "error: describe-log-groups succeeded under scoped deploy role (expected AccessDenied)" >&2
	exit 1
fi
grep -qiE 'AccessDenied|not authorized' "$OUT/sad-describe-log-groups.txt" || {
	echo "error: expected AccessDenied from describe-log-groups under ${BAD_ROLE}" >&2
	exit 1
}
grep -qi 'DescribeLogGroups' "$OUT/sad-describe-log-groups.txt" || {
	echo "error: AccessDenied did not name DescribeLogGroups" >&2
	exit 1
}
echo "ok   sad API: DescribeLogGroups AccessDenied under deploy role"

echo "==> sad: consumer deploy as --role-arn ${BAD_ROLE} (expect deny when CFN evaluates caller IAM)"
set +e
timeout --signal=KILL "$SLS_TIMEOUT_SECS" \
	"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" \
	--role-arn "$BAD_ARN" --session-name "sls4-role-bad" -- \
	deploy --stage "$STAGE" --verbose >"$OUT/deploy-consumer-sad.log" 2>&1
sad_rc=$?
set -e
cat "$OUT/deploy-consumer-sad.log"
grep -q "sls: deploying as" "$OUT/deploy-consumer-sad.log" || {
	echo "error: sad path missing principal line" >&2
	exit 1
}
grep -E "sls: deploying as .*${BAD_ROLE}" "$OUT/deploy-consumer-sad.log" || {
	echo "error: sad deploy did not run as ${BAD_ROLE}" >&2
	exit 1
}

events="$(aws cloudformation describe-stack-events --stack-name "$CONSUMER_STACK" \
	--query 'StackEvents[*].[ResourceStatus,ResourceStatusReason,ResourceType]' \
	--output text 2>/dev/null || true)"
printf '%s\n' "$events" >"$OUT/sad-events.txt"

if [[ "$sad_rc" -eq 0 ]]; then
	# LocalEmu CFN resource handlers currently elevate (#524). API deny above
	# still proves the role is wrong; deploy succeeding here is the known gap.
	CONSUMER_DEPLOYED=1
	if grep -qiE 'AccessDenied|not authorized' "$OUT/sad-events.txt"; then
		echo "error: deploy succeeded but stack events show AccessDenied (inconsistent)" >&2
		exit 1
	fi
	echo "ok   sad deploy: CFN elevated (no stack-event AccessDenied yet — see #524)"
else
	if ! grep -qiE 'AccessDenied|not authorized|User: .* is not authorized' \
		"$OUT/sad-events.txt" "$OUT/deploy-consumer-sad.log"; then
		echo "error: deploy failed without AccessDenied in events/log" >&2
		cat "$OUT/sad-events.txt" >&2 || true
		exit 1
	fi
	echo "ok   sad deploy denied (AccessDenied in stack events/log)"
	aws cloudformation delete-stack --stack-name "$CONSUMER_STACK" >/dev/null 2>&1 || true
fi

echo "OK: serverless v4 --role-arn happy+sad (${GOOD_ROLE} / ${BAD_ROLE})"
