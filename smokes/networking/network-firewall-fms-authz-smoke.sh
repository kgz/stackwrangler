#!/usr/bin/env bash
# Sad: deny-user network-firewall:CreateRuleGroup + fms:PutPolicy → AccessDenied (#440 / #677).
# Happy counterpart: ./smokes/networking/network-firewall-fms-smoke.sh
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
USER="awsbox-nfw-deny-${TS}"
POLICY_NAME="AwsboxDenyNfwFms-${TS}"
KEEP="${AWSBOX_NFW_KEEP:-${KEEP:-0}}"
DENIED_KEY="" POLICY_ARN=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-nfw-$$.json"
RG_FILE="${TMPDIR:-/tmp}/awsbox-deny-nfw-rg-$$.json"
FMS_FILE="${TMPDIR:-/tmp}/awsbox-deny-fms-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$POLICY_DOC" "$RG_FILE" "$FMS_FILE"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/stackwrangler up)" >&2
	exit 1
fi

cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":["network-firewall:CreateRuleGroup","fms:PutPolicy"],"Resource":"*"}]}
EOF
cat >"$RG_FILE" <<'EOF'
{
  "RulesSource": {
    "StatelessRulesAndCustomActions": {
      "StatelessRules": [{
        "Priority": 1,
        "RuleDefinition": {
          "Actions": ["aws:pass"],
          "MatchAttributes": { "Destinations": [{"AddressDefinition": "0.0.0.0/0"}], "Sources": [{"AddressDefinition": "0.0.0.0/0"}] }
        }
      }]
    }
  }
}
EOF

aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

set +e
OUT_NFW="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws network-firewall create-rule-group \
		--rule-group-name "denied-rg-${TS}" \
		--type STATELESS \
		--capacity 10 \
		--rule-group "file://${RG_FILE}" \
		2>&1)"
RC_NFW=$?
set -e
[[ "$RC_NFW" -ne 0 ]] || { echo "FAIL: create-rule-group succeeded" >&2; exit 1; }
echo "$OUT_NFW" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation' || {
	echo "FAIL: network-firewall: $OUT_NFW" >&2
	exit 1
}
echo "OK: network-firewall CreateRuleGroup AccessDenied"

cat >"$FMS_FILE" <<EOF
{
  "PolicyName": "denied-fms-${TS}",
  "RemediationEnabled": false,
  "ExcludeResourceTags": false,
  "ResourceType": "AWS::EC2::Instance",
  "SecurityServicePolicyData": {
    "Type": "WAFV2",
    "ManagedServiceData": "{\"type\":\"WAFV2\"}"
  }
}
EOF
set +e
OUT_FMS="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws fms put-policy --policy "file://${FMS_FILE}" 2>&1)"
RC_FMS=$?
set -e
[[ "$RC_FMS" -ne 0 ]] || { echo "FAIL: put-policy succeeded" >&2; exit 1; }
echo "$OUT_FMS" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation' || {
	echo "FAIL: fms: $OUT_FMS" >&2
	exit 1
}
echo "OK: fms PutPolicy AccessDenied"
