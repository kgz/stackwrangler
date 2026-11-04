#!/usr/bin/env bash
# WAFv2 control plane: WebACL (rate + managed-style rule) + associate to API GW stage.
# Rule evaluation is NOT real edge WAF — API store/associate only (docs/waf.md).
# Slice shape: examples/serverless-v3-rest/slices/waf/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
ACCOUNT="${AWSBOX_ACCOUNT_ID:-000000000000}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
ACL_NAME="awsbox-waf-${TS}"
API_NAME="awsbox-waf-api-${TS}"
STAGE="prod"
SSM_PARAM="/demo/waf/${TS}/web-acl-arn"
SLICE="$ROOT/examples/serverless-v3-rest/slices/waf"
KEEP="${AWSBOX_WAF_KEEP:-0}"
API_ID=""
ACL_ARN=""
ACL_ID=""
LOCK=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$ACL_ARN" && -n "$API_ID" ]] && \
		aws wafv2 disassociate-web-acl \
			--resource-arn "arn:aws:apigateway:${REGION}::/restapis/${API_ID}/stages/${STAGE}" \
			>/dev/null 2>&1 || true
	if [[ -n "$ACL_NAME" && -n "$ACL_ID" && -n "$LOCK" ]]; then
		aws wafv2 delete-web-acl --name "$ACL_NAME" --scope REGIONAL --id "$ACL_ID" --lock-token "$LOCK" \
			>/dev/null 2>&1 || true
	fi
	[[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1 || true
	aws ssm delete-parameter --name "$SSM_PARAM" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -f "$SLICE/template.yaml" ]] || { echo "FAIL: missing slice $SLICE/template.yaml" >&2; exit 1; }

# Classic WAF stub (ListWebACLs empty list — not Create).
CLASSIC="$(aws waf list-web-acls --output json)"
echo "$CLASSIC" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null

API_ID="$(aws apigateway create-rest-api --name "$API_NAME" --query id --output text)"
ROOT_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)"
aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$ROOT_ID" --http-method GET \
	--authorization-type NONE >/dev/null
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$ROOT_ID" --http-method GET \
	--type MOCK --request-templates '{"application/json":"{\"statusCode\":200}"}' >/dev/null
aws apigateway put-method-response --rest-api-id "$API_ID" --resource-id "$ROOT_ID" \
	--http-method GET --status-code 200 >/dev/null
aws apigateway put-integration-response --rest-api-id "$API_ID" --resource-id "$ROOT_ID" \
	--http-method GET --status-code 200 --selection-pattern '' >/dev/null
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" >/dev/null
STAGE_ARN="arn:aws:apigateway:${REGION}::/restapis/${API_ID}/stages/${STAGE}"

RULES_FILE="${TMPDIR:-/tmp}/awsbox-waf-rules-$$.json"
cat >"$RULES_FILE" <<'EOF'
[
  {
    "Name": "RateLimit",
    "Priority": 0,
    "Action": {"Block": {}},
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "RateLimit"
    },
    "Statement": {
      "RateBasedStatement": {
        "Limit": 100,
        "AggregateKeyType": "IP"
      }
    }
  },
  {
    "Name": "ManagedStyleBlock",
    "Priority": 1,
    "OverrideAction": {"None": {}},
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "ManagedStyleBlock"
    },
    "Statement": {
      "ManagedRuleGroupStatement": {
        "VendorName": "AWS",
        "Name": "AWSManagedRulesCommonRuleSet"
      }
    }
  }
]
EOF

CREATE="$(aws wafv2 create-web-acl \
	--name "$ACL_NAME" \
	--scope REGIONAL \
	--default-action Allow={} \
	--visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName="${ACL_NAME}" \
	--rules "file://${RULES_FILE}" \
	--description "awsbox waf smoke" \
	--output json)"
rm -f "$RULES_FILE"
ACL_ARN="$(echo "$CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Summary"]["ARN"])')"
ACL_ID="$(echo "$CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Summary"]["Id"])')"
LOCK="$(echo "$CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Summary"]["LockToken"])')"

aws ssm put-parameter --name "$SSM_PARAM" --type String --value "$ACL_ARN" --overwrite >/dev/null
SSM_VAL="$(aws ssm get-parameter --name "$SSM_PARAM" --query 'Parameter.Value' --output text)"
[[ "$SSM_VAL" == "$ACL_ARN" ]] || { echo "FAIL: SSM ACL ARN mismatch" >&2; exit 1; }

aws wafv2 associate-web-acl --web-acl-arn "$ACL_ARN" --resource-arn "$STAGE_ARN" >/dev/null

FOR_RES="$(aws wafv2 get-web-acl-for-resource --resource-arn "$STAGE_ARN" --output json)"
GOT_ARN="$(echo "$FOR_RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["WebACL"]["ARN"])')"
[[ "$GOT_ARN" == "$ACL_ARN" ]] || { echo "FAIL: get-web-acl-for-resource $GOT_ARN != $ACL_ARN" >&2; exit 1; }

LISTED="$(aws wafv2 list-resources-for-web-acl --web-acl-arn "$ACL_ARN" --output json)"
echo "$LISTED" | STAGE_ARN="$STAGE_ARN" python3 -c '
import json, os, sys
arns = json.load(sys.stdin).get("ResourceArns") or []
want = os.environ["STAGE_ARN"]
if want not in arns:
    raise SystemExit(f"FAIL: stage not in list-resources-for-web-acl: {arns}")
'

# Refresh lock for cleanup delete
LOCK="$(aws wafv2 get-web-acl --name "$ACL_NAME" --scope REGIONAL --id "$ACL_ID" \
	--query 'LockToken' --output text)"

echo "OK: wafv2 WebACL + associate (${ACL_NAME})"
echo "NOTE: rule evaluation is not real edge WAF — control-plane / association only"
echo "OK: waf classic ListWebACLs stub"
echo "OK: SSM ${SSM_PARAM} → ACL ARN (slice shape)"
