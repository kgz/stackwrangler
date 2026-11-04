#!/usr/bin/env bash
# Happy: put EventBridge events → list rules (bus default).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
RULE="awsbox-eb-${TS}"
KEEP="${AWSBOX_EVENTS_KEEP:-0}"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws events remove-targets --rule "$RULE" --ids "1" >/dev/null 2>&1 || true
	aws events delete-rule --name "$RULE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
ENTRIES="$(python3 -c "import json; print(json.dumps([{'Source':'awsbox.smoke','DetailType':'ping','Detail':json.dumps({'ts':$TS})}]))")"
aws events put-events --entries "$ENTRIES" --query 'FailedEntryCount' --output text | grep -qx 0
aws events put-rule --name "$RULE" --event-pattern '{"source":["awsbox.smoke"]}' --state ENABLED >/dev/null
aws events describe-rule --name "$RULE" --query 'Name' --output text | grep -qx "$RULE"
echo "OK: events put-events + rule (${RULE})"
