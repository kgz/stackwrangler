#!/usr/bin/env bash
# #751: restored Lambda versions must wait for the gateway, not fail while a slow state load
# (here: an RDS instance's startup reconcile) keeps :4566 closed past the 30s per-version budget.
# Live: brings this worktree's stack up in --dev (gate first: ./bin/batch-resource-gate.sh check --need-up).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

TS="$(date +%s)"
FN="sw751-${TS}"
DB="sw751-${TS}"
MODE_BAK=test
[[ -f "$ROOT/.awsbox/mode" ]] && MODE_BAK="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
tmp="$(mktemp -d)"

fail() { echo "FAIL: $*" >&2; exit 1; }
aws() { command aws --endpoint-url "$EP" --region "$REGION" --cli-connect-timeout 10 --cli-read-timeout 120 "$@"; }

cleanup() {
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot >/dev/null 2>&1 || true
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	printf '%s\n' "$MODE_BAK" >"$ROOT/.awsbox/mode"
	rm -rf "$tmp"
}
trap cleanup EXIT

state() { aws lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || echo missing; }

"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

# Slow startup reconcile: RDS resume probe holds the gateway closed for ~60s after a restart.
aws rds create-db-instance --db-instance-identifier "$DB" --engine postgres --engine-version 16.4 \
	--db-instance-class db.t3.micro --master-username sw --master-user-password sw751pass --allocated-storage 20 >/dev/null
aws rds wait db-instance-available --db-instance-identifier "$DB"

printf 'def handler(event, context):\n    return "ok"\n' >"$tmp/index.py"
(cd "$tmp" && python3 -c 'import zipfile; z = zipfile.ZipFile("fn.zip", "w"); z.write("index.py"); z.close()')
aws lambda create-function --function-name "$FN" --runtime python3.12 --handler index.handler \
	--role arn:aws:iam::000000000000:role/sw751 --zip-file "fileb://$tmp/fn.zip" >/dev/null
aws lambda wait function-active-v2 --function-name "$FN"
echo "OK: function Active before restart"

"$ROOT/bin/stackwrangler" down
"$ROOT/bin/stackwrangler" up --dev

s=missing
for _ in $(seq 1 240); do
	s="$(state)"
	[[ "$s" == Active || "$s" == Failed ]] && break
	sleep 1
done
[[ "$s" == Active ]] || fail "restored function is $s, not Active"
aws lambda invoke --function-name "$FN" "$tmp/out.json" >/dev/null
grep -q ok "$tmp/out.json" || fail "invoke after restore returned $(cat "$tmp/out.json")"
echo "OK: lambda-restore-gateway-wait (#751)"
