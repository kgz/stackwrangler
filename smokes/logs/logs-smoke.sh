#!/usr/bin/env bash
# Invoke hello Lambda then assert a log group / events exist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

IAM_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

FN="${1:-awsbox-hello}"
"$ROOT/bin/lambda-smoke.sh" "$FN" >/dev/null

GROUP="/aws/lambda/${FN}"
echo "waiting for log group ${GROUP}…"
for _ in $(seq 1 30); do
	if aws --endpoint-url "$IAM_EP" --region "$REGION" logs describe-log-groups \
		--log-group-name-prefix "$GROUP" \
		--query "logGroups[?logGroupName=='${GROUP}'].logGroupName" \
		--output text 2>/dev/null | grep -q "$GROUP"; then
		break
	fi
	sleep 2
done

aws --endpoint-url "$IAM_EP" --region "$REGION" logs describe-log-groups \
	--log-group-name-prefix "$GROUP" \
	--query "logGroups[?logGroupName=='${GROUP}'].logGroupName" \
	--output text | grep -q "$GROUP"

EVENTS="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" logs filter-log-events \
		--log-group-name "$GROUP" --limit 20 --output json
)"
echo "$EVENTS" | grep -qiE 'START RequestId|REPORT RequestId|ok|ping|INIT' \
	|| echo "$EVENTS" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("events"), d'

echo "OK: logs for ${GROUP}"
