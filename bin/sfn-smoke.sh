#!/usr/bin/env bash
# Happy: create Pass-state machine → start execution → succeed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
NAME="awsbox-sfn-${TS}"
KEEP="${AWSBOX_SFN_KEEP:-0}"
SM_ARN=""
ROLE="awsbox-sfn-role-${TS}"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SM_ARN" ]] && aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
DEF='{"Comment":"awsbox","StartAt":"Hi","States":{"Hi":{"Type":"Pass","Result":{"ok":true},"End":true}}}'
SM_ARN="$(aws stepfunctions create-state-machine --name "$NAME" --definition "$DEF" --role-arn "$ROLE_ARN" --query 'stateMachineArn' --output text)"
EXEC="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "run-${TS}" --query 'executionArn' --output text)"
for _ in $(seq 1 30); do
	st="$(aws stepfunctions describe-execution --execution-arn "$EXEC" --query 'status' --output text)"
	[[ "$st" == "SUCCEEDED" ]] && break
	[[ "$st" == "FAILED" || "$st" == "TIMED_OUT" || "$st" == "ABORTED" ]] && {
		echo "FAIL: execution ${st}" >&2
		aws stepfunctions describe-execution --execution-arn "$EXEC" >&2
		exit 1
	}
	sleep 1
done
[[ "$st" == "SUCCEEDED" ]]
echo "OK: stepfunctions Pass execution (${NAME})"
