#!/usr/bin/env bash
# Scheduled EventBridge rule (rate(1 minute)) invokes a Lambda.
# Happy: rate(1 minute) >=2 invocations in the window, none after disable-rule;
#        cron(* * * * ? *) invokes too.
# Sad: rule without lambda:InvokeFunction permission never invokes the target.
# Slice: examples/serverless-v3-rest/slices/schedule (#297)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLICE="$ROOT/examples/serverless-v3-rest/slices/schedule"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

WINDOW="${AWSBOX_SCHEDULE_WINDOW:-180}"
QUIET="${AWSBOX_SCHEDULE_QUIET:-90}"
KEEP="${AWSBOX_SCHEDULE_KEEP:-0}"
TS="$(date +%s)"
CODE_BUCKET="awsbox-sched-code-${TS}"
STACKS=()
WORK=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	local s
	for s in "${STACKS[@]:-}"; do
		[[ -n "$s" ]] || continue
		aws cloudformation delete-stack --stack-name "$s" >/dev/null 2>&1 || true
	done
	aws s3 rb "s3://${CODE_BUCKET}" --force >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

FAILS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

deploy() { # stack fn rule state grant [schedule]
	STACKS+=("$1")
	aws cloudformation deploy \
		--stack-name "$1" \
		--template-file "$SLICE/template.yaml" \
		--capabilities CAPABILITY_NAMED_IAM \
		--no-fail-on-empty-changeset \
		--parameter-overrides \
		"FunctionName=$2" "RuleName=$3" "RuleState=$4" "GrantInvoke=$5" \
		"ScheduleExpression=${6:-rate(1 minute)}" \
		"CodeBucket=${CODE_BUCKET}" "CodeKey=function.zip" >/dev/null
	local st
	for _ in $(seq 1 60); do
		st="$(aws lambda get-function --function-name "$2" \
			--query 'Configuration.State' --output text 2>/dev/null || echo Pending)"
		[[ "$st" == "Active" ]] && return 0
		sleep 2
	done
	fail "$2 never became Active (state=${st})"
}

# Invocations are counted from the sweep-tick line the handler logs.
count_invocations() {
	local n
	n="$(aws logs filter-log-events --log-group-name "/aws/lambda/$1" \
		--filter-pattern '"sweep-tick"' --query 'length(events)' --output text 2>/dev/null || echo 0)"
	[[ "$n" =~ ^[0-9]+$ ]] || n=0
	echo "$n"
}

WORK="$(mktemp -d)"
ZIP="$WORK/function.zip"
(cd "$SLICE/src" && zip -q "$ZIP" index.js)
aws s3 mb "s3://${CODE_BUCKET}" >/dev/null
aws s3 cp "$ZIP" "s3://${CODE_BUCKET}/function.zip" >/dev/null

# One stack per scenario, deployed together so the windows overlap.
FN="awsbox-sched-${TS}"
RULE="awsbox-sched-rule-${TS}"
FN_NOPERM="awsbox-sched-noperm-${TS}"
FN_CRON="awsbox-sched-cron-${TS}"
RULE_CRON="awsbox-sched-cron-rule-${TS}"
deploy "awsbox-sched-noperm-${TS}" "$FN_NOPERM" "awsbox-sched-noperm-rule-${TS}" ENABLED false
deploy "awsbox-sched-cron-${TS}" "$FN_CRON" "$RULE_CRON" ENABLED true 'cron(* * * * ? *)'
deploy "awsbox-sched-${TS}" "$FN" "$RULE" ENABLED true

aws events describe-rule --name "$RULE" --query 'ScheduleExpression' --output text | grep -qx 'rate(1 minute)' \
	|| fail "rule ${RULE} missing rate(1 minute)"
aws events list-targets-by-rule --rule "$RULE" --query 'Targets[0].Arn' --output text | grep -q ":function:${FN}\$" \
	|| fail "rule ${RULE} target is not ${FN}"
if aws lambda get-policy --function-name "$FN_NOPERM" --query Policy --output text 2>/dev/null | grep -q 'events.amazonaws.com'; then
	fail "${FN_NOPERM} unexpectedly has an events.amazonaws.com policy"
fi

echo "waiting up to ${WINDOW}s for >=2 scheduled invocations of ${FN}…"
N=0
NC=0
deadline=$((SECONDS + WINDOW))
while ((SECONDS < deadline)); do
	N="$(count_invocations "$FN")"
	NC="$(count_invocations "$FN_CRON")"
	((N >= 2 && NC >= 1)) && break
	sleep 5
done
((N >= 2)) || check "expected >=2 rate(1 minute) invocations in ${WINDOW}s, got ${N}"
((NC >= 1)) || check "expected cron(* * * * ? *) to invoke ${FN_CRON} in ${WINDOW}s, got ${NC}"
echo "invocations: rate=${N} cron=${NC}"

aws events disable-rule --name "$RULE"
aws events describe-rule --name "$RULE" --query 'State' --output text | grep -qx DISABLED \
	|| fail "rule ${RULE} not DISABLED"
# Let an invocation already in flight finish before taking the baseline.
sleep 10
BASE="$(count_invocations "$FN")"
echo "disabled; baseline=${BASE}; watching ${QUIET}s…"
sleep "$QUIET"
AFTER="$(count_invocations "$FN")"
[[ "$AFTER" == "$BASE" ]] || check "disabled rule still invoked ${FN} (${BASE} -> ${AFTER})"

# The no-permission rule has been live for the whole run above.
N2="$(count_invocations "$FN_NOPERM")"
[[ "$N2" == "0" ]] || check "rule without invoke permission invoked ${FN_NOPERM} ${N2} time(s)"

((FAILS == 0)) || exit 1
echo "OK: events schedule rate x${N} none after disable; cron x${NC}; none without permission (${FN_NOPERM})"
