#!/usr/bin/env bash
# #109: Network Firewall policy/rule-group + Firewall Manager policy stubs.
# Control plane only — no packet filtering / org enforcement data plane.
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
RG_NAME="awsbox-nfw-rg-${TS}"
POLICY_NAME="awsbox-nfw-pol-${TS}"
FMS_NAME="awsbox-fms-${TS}"
KEEP="${AWSBOX_NFW_KEEP:-${KEEP:-0}}"
RG_ARN=""
FW_POLICY_ARN=""
FMS_POLICY_ID=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$FMS_POLICY_ID" ]] && aws fms delete-policy --policy-id "$FMS_POLICY_ID" >/dev/null 2>&1 || true
	[[ -n "$FW_POLICY_ARN" ]] && aws network-firewall delete-firewall-policy \
		--firewall-policy-arn "$FW_POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$RG_ARN" ]] && aws network-firewall delete-rule-group \
		--rule-group-arn "$RG_ARN" --type STATELESS >/dev/null 2>&1 || true
}
trap cleanup EXIT

RG_FILE="${TMPDIR:-/tmp}/awsbox-nfw-rg-$$.json"
POLICY_FILE="${TMPDIR:-/tmp}/awsbox-nfw-pol-$$.json"
cat >"$RG_FILE" <<'EOF'
{
  "RulesSource": {
    "StatelessRulesAndCustomActions": {
      "StatelessRules": [
        {
          "Priority": 1,
          "RuleDefinition": {
            "Actions": ["aws:pass"],
            "MatchAttributes": {
              "Sources": [{"AddressDefinition": "0.0.0.0/0"}],
              "Destinations": [{"AddressDefinition": "0.0.0.0/0"}],
              "Protocols": [6]
            }
          }
        }
      ]
    }
  }
}
EOF

RG_CREATE="$(aws network-firewall create-rule-group \
	--rule-group-name "$RG_NAME" \
	--type STATELESS \
	--capacity 10 \
	--rule-group "file://${RG_FILE}" \
	--description "awsbox nfw smoke" \
	--output json)"
rm -f "$RG_FILE"
RG_ARN="$(echo "$RG_CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["RuleGroupResponse"]["RuleGroupArn"])')"

RG_DESC="$(aws network-firewall describe-rule-group --rule-group-arn "$RG_ARN" --output json)"
echo "$RG_DESC" | RG_ARN="$RG_ARN" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
assert doc["RuleGroupResponse"]["RuleGroupArn"] == os.environ["RG_ARN"]
assert "RulesSource" in doc["RuleGroup"]
'

RG_LIST="$(aws network-firewall list-rule-groups --output json)"
echo "$RG_LIST" | RG_ARN="$RG_ARN" python3 -c '
import json, os, sys
arns = [x.get("Arn") for x in json.load(sys.stdin).get("RuleGroups") or []]
if os.environ["RG_ARN"] not in arns:
    raise SystemExit(f"FAIL: rule group missing from list: {arns}")
'

cat >"$POLICY_FILE" <<EOF
{
  "StatelessDefaultActions": ["aws:forward_to_sfe"],
  "StatelessFragmentDefaultActions": ["aws:forward_to_sfe"],
  "StatelessRuleGroupReferences": [
    {"ResourceArn": "${RG_ARN}", "Priority": 10}
  ]
}
EOF

POL_CREATE="$(aws network-firewall create-firewall-policy \
	--firewall-policy-name "$POLICY_NAME" \
	--firewall-policy "file://${POLICY_FILE}" \
	--description "awsbox nfw smoke policy" \
	--output json)"
rm -f "$POLICY_FILE"
FW_POLICY_ARN="$(echo "$POL_CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["FirewallPolicyResponse"]["FirewallPolicyArn"])')"

POL_DESC="$(aws network-firewall describe-firewall-policy --firewall-policy-arn "$FW_POLICY_ARN" --output json)"
echo "$POL_DESC" | FW_POLICY_ARN="$FW_POLICY_ARN" RG_ARN="$RG_ARN" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
assert doc["FirewallPolicyResponse"]["FirewallPolicyArn"] == os.environ["FW_POLICY_ARN"]
refs = doc["FirewallPolicy"].get("StatelessRuleGroupReferences") or []
arns = [r.get("ResourceArn") for r in refs]
if os.environ["RG_ARN"] not in arns:
    raise SystemExit(f"FAIL: policy missing rule group ref: {arns}")
'

POL_LIST="$(aws network-firewall list-firewall-policies --output json)"
echo "$POL_LIST" | FW_POLICY_ARN="$FW_POLICY_ARN" python3 -c '
import json, os, sys
arns = [x.get("Arn") for x in json.load(sys.stdin).get("FirewallPolicies") or []]
if os.environ["FW_POLICY_ARN"] not in arns:
    raise SystemExit(f"FAIL: firewall policy missing from list: {arns}")
'

FMS_FILE="${TMPDIR:-/tmp}/awsbox-fms-$$.json"
cat >"$FMS_FILE" <<EOF
{
  "PolicyName": "${FMS_NAME}",
  "RemediationEnabled": false,
  "ExcludeResourceTags": false,
  "ResourceType": "AWS::EC2::Instance",
  "SecurityServicePolicyData": {
    "Type": "WAFV2",
    "ManagedServiceData": "{\"type\":\"WAFV2\"}"
  }
}
EOF

FMS_PUT="$(aws fms put-policy --policy "file://${FMS_FILE}" --output json)"
rm -f "$FMS_FILE"
FMS_POLICY_ID="$(echo "$FMS_PUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Policy"]["PolicyId"])')"
FMS_ARN="$(echo "$FMS_PUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PolicyArn"])')"

FMS_GET="$(aws fms get-policy --policy-id "$FMS_POLICY_ID" --output json)"
echo "$FMS_GET" | FMS_ARN="$FMS_ARN" FMS_NAME="$FMS_NAME" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
assert doc["PolicyArn"] == os.environ["FMS_ARN"]
assert doc["Policy"]["PolicyName"] == os.environ["FMS_NAME"]
'

FMS_LIST="$(aws fms list-policies --output json)"
echo "$FMS_LIST" | FMS_POLICY_ID="$FMS_POLICY_ID" python3 -c '
import json, os, sys
ids = [x.get("PolicyId") for x in json.load(sys.stdin).get("PolicyList") or []]
if os.environ["FMS_POLICY_ID"] not in ids:
    raise SystemExit(f"FAIL: fms policy missing from list: {ids}")
'

APPS="$(aws fms list-apps-lists --max-results 100 --output json)"
echo "$APPS" | python3 -c 'import json,sys; assert "AppsLists" in json.load(sys.stdin)'

echo "OK: network-firewall rule group + firewall policy (${RG_NAME})"
echo "OK: fms put/get/list policy (${FMS_NAME})"
echo "NOTE: no packet filtering / org policy enforcement — control plane only"
