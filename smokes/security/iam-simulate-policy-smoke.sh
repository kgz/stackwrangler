#!/usr/bin/env bash
# IAM SimulateCustomPolicy / SimulatePrincipalPolicy via the enforcer evaluator.
# Cases: allowed, implicitDeny, explicitDeny, condition via ContextEntries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
ROLE="awsbox-sim-${TS}"
ACCOUNT="000000000000"
TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT}:t"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-publish >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

decision() {
	python3 -c 'import json,sys; print(json.load(sys.stdin)["EvaluationResults"][0]["EvalDecision"])'
}

echo "==> SimulateCustomPolicy allowed"
ALLOW_POL='{"Version":"2012-10-17","Statement":[{"Sid":"AllowPublish","Effect":"Allow","Action":"sns:Publish","Resource":"*"}]}'
OUT="$(aws iam simulate-custom-policy \
	--policy-input-list "$ALLOW_POL" \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "allowed" ]] || {
	echo "FAIL: expected allowed, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
echo "$OUT" | python3 -c '
import json,sys
r=json.load(sys.stdin)["EvaluationResults"][0]
assert r.get("MatchedStatements"), r
print("allowed ok; MatchedStatements=", len(r["MatchedStatements"]))
'

echo "==> SimulateCustomPolicy implicitDeny (empty policy)"
OUT="$(aws iam simulate-custom-policy \
	--policy-input-list '{"Version":"2012-10-17","Statement":[]}' \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "implicitDeny" ]] || {
	echo "FAIL: expected implicitDeny, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
echo "implicitDeny ok"

echo "==> SimulateCustomPolicy explicitDeny"
DENY_POL='{"Version":"2012-10-17","Statement":[{"Sid":"DenyPublish","Effect":"Deny","Action":"sns:Publish","Resource":"*"},{"Sid":"AllowPublish","Effect":"Allow","Action":"sns:Publish","Resource":"*"}]}'
OUT="$(aws iam simulate-custom-policy \
	--policy-input-list "$DENY_POL" \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "explicitDeny" ]] || {
	echo "FAIL: expected explicitDeny, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
echo "explicitDeny ok"

echo "==> SimulateCustomPolicy condition via ContextEntries"
COND_POL='{"Version":"2012-10-17","Statement":[{"Sid":"Cond","Effect":"Allow","Action":"sns:Publish","Resource":"*","Condition":{"StringEquals":{"aws:RequestedRegion":"us-east-1"}}}]}'
OUT="$(aws iam simulate-custom-policy \
	--policy-input-list "$COND_POL" \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "implicitDeny" ]] || {
	echo "FAIL: without ContextEntries expected implicitDeny, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
MISSING="$(echo "$OUT" | python3 -c '
import json,sys
print(",".join(json.load(sys.stdin)["EvaluationResults"][0].get("MissingContextValues") or []))
')"
[[ "$MISSING" == *aws:RequestedRegion* ]] || {
	echo "FAIL: expected MissingContextValues to include aws:RequestedRegion, got '$MISSING'" >&2
	echo "$OUT" >&2
	exit 1
}

OUT="$(aws iam simulate-custom-policy \
	--policy-input-list "$COND_POL" \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--context-entries "ContextKeyName=aws:RequestedRegion,ContextKeyValues=us-east-1,ContextKeyType=string" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "allowed" ]] || {
	echo "FAIL: with ContextEntries expected allowed, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
echo "ContextEntries condition ok"

echo "==> SimulatePrincipalPolicy (role inline allow)"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name allow-publish --policy-document "$ALLOW_POL" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

OUT="$(aws iam simulate-principal-policy \
	--policy-source-arn "$ROLE_ARN" \
	--action-names sns:Publish \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "allowed" ]] || {
	echo "FAIL: principal simulate expected allowed, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}

OUT="$(aws iam simulate-principal-policy \
	--policy-source-arn "$ROLE_ARN" \
	--action-names sns:Subscribe \
	--resource-arns "$TOPIC_ARN" \
	--output json)"
DEC="$(echo "$OUT" | decision)"
[[ "$DEC" == "implicitDeny" ]] || {
	echo "FAIL: principal simulate Subscribe expected implicitDeny, got $DEC" >&2
	echo "$OUT" >&2
	exit 1
}
echo "SimulatePrincipalPolicy ok"

echo "OK: iam simulate-custom-policy / simulate-principal-policy"
