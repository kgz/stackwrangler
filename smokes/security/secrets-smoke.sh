#!/usr/bin/env bash
# Happy: create secret → get value → delete.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
NAME="awsbox/secret-${TS}"
KEEP="${AWSBOX_SECRETS_KEEP:-0}"
ARN=""
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$ARN" ]] && aws secretsmanager delete-secret --secret-id "$ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
}
trap cleanup EXIT
ARN="$(aws secretsmanager create-secret --name "$NAME" --secret-string "awsbox-${TS}" --query 'ARN' --output text)"
VAL="$(aws secretsmanager get-secret-value --secret-id "$ARN" --query 'SecretString' --output text)"
[[ "$VAL" == "awsbox-${TS}" ]]
echo "OK: secretsmanager create/get (${NAME})"
