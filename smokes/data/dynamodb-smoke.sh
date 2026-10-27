#!/usr/bin/env bash
# Happy: create table → put/get item → delete table.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
TABLE="awsbox-ddb-${TS}"
KEEP="${AWSBOX_DDB_KEEP:-0}"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
aws dynamodb create-table \
	--table-name "$TABLE" \
	--attribute-definitions AttributeName=pk,AttributeType=S \
	--key-schema AttributeName=pk,KeyType=HASH \
	--billing-mode PAY_PER_REQUEST >/dev/null
for _ in $(seq 1 30); do
	st="$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
aws dynamodb put-item --table-name "$TABLE" --item '{"pk":{"S":"one"},"note":{"S":"awsbox"}}' >/dev/null
NOTE="$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"one"}}' --query 'Item.note.S' --output text)"
[[ "$NOTE" == "awsbox" ]]
echo "OK: dynamodb put/get (${TABLE})"
