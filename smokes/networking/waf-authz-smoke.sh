#!/usr/bin/env bash
# Sad: deny-user wafv2:CreateWebACL → AccessDenied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
USER="awsbox-waf-deny-${TS}"
POLICY_NAME="AwsboxDenyWafCreate-${TS}"
KEEP="${AWSBOX_WAF_KEEP:-0}"
DENIED_KEY="" POLICY_ARN=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-waf-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$POLICY_DOC"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"wafv2:CreateWebACL","Resource":"*"}]}
EOF
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws wafv2 create-web-acl \
		--name "denied-${TS}" \
		--scope REGIONAL \
		--default-action Allow={} \
		--visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=denied \
		2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: create-web-acl succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' || { echo "FAIL: $OUT" >&2; exit 1; }
echo "OK: wafv2 CreateWebACL AccessDenied"
