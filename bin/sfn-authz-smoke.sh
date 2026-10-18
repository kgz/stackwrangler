#!/usr/bin/env bash
# Sad: deny-user states:StartExecution → AccessDenied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
NAME="awsbox-sfn-authz-${TS}"
ROLE="awsbox-sfn-authz-role-${TS}"
USER="awsbox-sfn-deny-${TS}"
POLICY_NAME="AwsboxDenySfnStart-${TS}"
KEEP="${AWSBOX_SFN_KEEP:-0}"
SM_ARN="" DENIED_KEY="" POLICY_ARN=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-sfn-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$POLICY_DOC"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SM_ARN" ]] && aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
DEF='{"StartAt":"Hi","States":{"Hi":{"Type":"Pass","End":true}}}'
SM_ARN="$(aws stepfunctions create-state-machine --name "$NAME" --definition "$DEF" --role-arn "$ROLE_ARN" --query 'stateMachineArn' --output text)"
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"states:StartExecution","Resource":"*"}]}
EOF
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "deny-${TS}" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: start-execution succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' || { echo "FAIL: $OUT" >&2; exit 1; }
echo "OK: stepfunctions StartExecution AccessDenied"
echo "$OUT" | head -2
