#!/usr/bin/env bash
# REST API keys + usage plans (examples/serverless-v3-rest/slices/api-keys, docs/apigw-rest.md).
# Happy: token-admin Lambda mints a key (CreateApiKey + CreateUsagePlanKey after GetUsagePlans by name);
#        x-api-key call 200; route without apiKeyRequired 200 with no key.
#        apiKeySource AUTHORIZER takes the key from the authorizer's usageIdentifierKey.
# Sad:   no key 403; unknown key 403; revoked (DeleteApiKey) key 403; disabled key 403;
#        burst past the plan throttle 429; quota exhausted 429;
#        role without apigateway:POST on /apikeys cannot mint (AccessDenied, no key created).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
ACCOUNT="000000000000"
TS="$(date +%s)"
SLICE="$ROOT/examples/serverless-v3-rest/slices/api-keys"
WORK="$(mktemp -d)"
HANDLER="awsbox-keys-handler-${TS}"
ADMIN="awsbox-keys-admin-${TS}"
ADMIN_DENIED="awsbox-keys-admin-denied-${TS}"
AUTHZ="awsbox-keys-authz-${TS}"
ROLE_BACKEND="awsbox-keys-backend-${TS}"
ROLE_ADMIN="awsbox-keys-admin-${TS}"
ROLE_DENIED="awsbox-keys-denied-${TS}"
PLAN_STD="standard-${TS}"
PLAN_TIGHT="tight-${TS}"
PLAN_CAP="capped-${TS}"
PLAN_AUTHZ="authz-${TS}"
KEEP="${AWSBOX_APIGW_KEEP:-0}"
API_ID=""
API2_ID=""
PLAN_IDS=()
KEY_IDS=()
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
AGW="arn:aws:apigateway:${REGION}::"
ADMIN_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"apigateway:POST\",\"apigateway:GET\",\"apigateway:DELETE\"],\"Resource\":[\"${AGW}/apikeys\",\"${AGW}/apikeys/*\",\"${AGW}/usageplans\",\"${AGW}/usageplans/*\"]}]}"
DENIED_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"apigateway:GET\",\"Resource\":[\"${AGW}/usageplans\",\"${AGW}/usageplans/*\"]}]}"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1 || true
	[[ -n "$API2_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API2_ID" >/dev/null 2>&1 || true
	for k in "${KEY_IDS[@]:-}"; do [[ -n "$k" ]] && aws apigateway delete-api-key --api-key "$k" >/dev/null 2>&1 || true; done
	for p in "${PLAN_IDS[@]:-}"; do [[ -n "$p" ]] && aws apigateway delete-usage-plan --usage-plan-id "$p" >/dev/null 2>&1 || true; done
	for fn in "$HANDLER" "$ADMIN" "$ADMIN_DENIED" "$AUTHZ"; do aws lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true; done
	aws iam delete-role-policy --role-name "$ROLE_ADMIN" --policy-name keys >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE_DENIED" --policy-name keys >/dev/null 2>&1 || true
	for r in "$ROLE_BACKEND" "$ROLE_ADMIN" "$ROLE_DENIED"; do aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

FAIL=0
check() {
	local label="$1" want="$2" got="$3" body="${4:-}"
	if [[ "$got" == "$want" ]]; then
		echo "ok   ${label}: ${got}"
	else
		echo "FAIL ${label}: got ${got}, want ${want} ${body}" >&2
		FAIL=1
	fi
}
req() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
jget() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v.get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || echo ""; }

python3 - "$SLICE" "$WORK" <<'PY'
import sys, zipfile
src, work = sys.argv[1], sys.argv[2]
for name in ("handler", "token-admin", "authorizer"):
    with zipfile.ZipFile(f"{work}/{name}.zip", "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.write(f"{src}/{name}.js", "index.js")
PY

mk_role() { # name [policy]
	aws iam create-role --role-name "$1" --assume-role-policy-document "$TRUST" >/dev/null
	[[ -n "${2:-}" ]] && aws iam put-role-policy --role-name "$1" --policy-name keys --policy-document "$2"
	return 0
}
mk_role "$ROLE_BACKEND"
mk_role "$ROLE_ADMIN" "$ADMIN_POLICY"
mk_role "$ROLE_DENIED" "$DENIED_POLICY"
role_arn() { aws iam get-role --role-name "$1" --query Role.Arn --output text; }

mk_fn() { # name role zip
	aws lambda create-function --function-name "$1" --runtime nodejs20.x --role "$(role_arn "$2")" \
		--handler index.handler --timeout 30 --zip-file "fileb://${WORK}/$3.zip" >/dev/null
}
mk_fn "$HANDLER" "$ROLE_BACKEND" handler
mk_fn "$ADMIN" "$ROLE_ADMIN" token-admin
mk_fn "$ADMIN_DENIED" "$ROLE_DENIED" token-admin
mk_fn "$AUTHZ" "$ROLE_BACKEND" authorizer
for fn in "$HANDLER" "$ADMIN" "$ADMIN_DENIED" "$AUTHZ"; do
	for _ in $(seq 1 60); do
		[[ "$(aws lambda get-function --function-name "$fn" --query Configuration.State --output text)" == "Active" ]] && break
		sleep 2
	done
done

HANDLER_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT}:function:${HANDLER}/invocations" \
	python3 -c 'import os,sys; print(open(sys.argv[1]).read().replace("${HANDLER_URI}", os.environ["HANDLER_URI"]))' \
	"$SLICE/openapi.template.json" >"$WORK/openapi.json"

API_ID="$(aws apigateway import-rest-api --body "fileb://${WORK}/openapi.json" --query id --output text)"
aws lambda add-permission --function-name "$HANDLER" --statement-id "apigw-${TS}" --action lambda:InvokeFunction \
	--principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*" >/dev/null
aws apigateway update-rest-api --rest-api-id "$API_ID" --patch-operations op=replace,path=/apiKeySource,value=HEADER >/dev/null
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name local >/dev/null
BASE="${EP}/restapis/${API_ID}/local/_user_request_"

mk_plan_for() { # api-id name extra-args... -> id
	local api="$1" name="$2"; shift 2
	aws apigateway create-usage-plan --name "$name" --api-stages "apiId=${api},stage=local" "$@" --query id --output text
}
mk_plan() { mk_plan_for "$API_ID" "$@"; }
P_STD="$(mk_plan "$PLAN_STD" --throttle rateLimit=50,burstLimit=100)"
P_TIGHT="$(mk_plan "$PLAN_TIGHT" --throttle rateLimit=1,burstLimit=2)"
P_CAP="$(mk_plan "$PLAN_CAP" --throttle rateLimit=50,burstLimit=100 --quota limit=4,offset=1,period=DAY)"
PLAN_IDS=("$P_STD" "$P_TIGHT" "$P_CAP")

mint() { # fn plan name -> sets KID, KVAL
	aws lambda invoke --function-name "$1" --cli-binary-format raw-in-base64-out \
		--payload "{\"action\":\"mint\",\"plan\":\"$2\",\"name\":\"$3\"}" "$WORK/mint.json" >/dev/null
	KID="$(jget "$WORK/mint.json" keyId)"
	KVAL="$(jget "$WORK/mint.json" value)"
	[[ -n "$KID" ]] && KEY_IDS+=("$KID")
	return 0
}
revoke() {
	aws lambda invoke --function-name "$ADMIN" --cli-binary-format raw-in-base64-out \
		--payload "{\"action\":\"revoke\",\"keyId\":\"$1\"}" "$WORK/revoke.json" >/dev/null
	jget "$WORK/revoke.json" ok
}

echo "== Lambda mints keys at runtime =="
mint "$ADMIN" "$PLAN_STD" "client-${TS}"
check "happy mint via Lambda" "ok" "$([[ -n "$KID" && -n "$KVAL" ]] && echo ok || echo "no-key $(cat "$WORK/mint.json")")"
check "happy plan keys listed" "$KID" "$(aws apigateway get-usage-plan-keys --usage-plan-id "$P_STD" --query 'items[0].id' --output text)"
check "happy get-api-key" "client-${TS}" "$(aws apigateway get-api-key --api-key "$KID" --query name --output text)"

echo "== enforcement =="
check "happy open route needs no key" 200 "$(req "${BASE}/public/ping")"
check "happy valid key" 200 "$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items")" "$(cat "$WORK/body")"
check "sad no key" 403 "$(req "${BASE}/v1/items")"
check "sad no key body" "Forbidden" "$(jget "$WORK/body" message)"
check "sad unknown key" 403 "$(req -H "x-api-key: not-a-real-key-${TS}" "${BASE}/v1/items")"

aws apigateway update-api-key --api-key "$KID" --patch-operations op=replace,path=/enabled,value=false >/dev/null
check "sad disabled key" 403 "$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items")"
aws apigateway update-api-key --api-key "$KID" --patch-operations op=replace,path=/enabled,value=true >/dev/null
check "happy re-enabled key" 200 "$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items")"

check "happy revoke via Lambda" True "$(revoke "$KID")"
check "sad revoked key" 403 "$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items")"

echo "== throttle (plan rate 1/s, burst 2) =="
mint "$ADMIN" "$PLAN_TIGHT" "tight-${TS}"
CODES=""
for _ in $(seq 1 6); do CODES+="$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items") "; done
check "happy burst allowed first" 200 "${CODES%% *}"
check "sad throttle past burst" 429 "$(echo "$CODES" | tr ' ' '\n' | grep -m1 -x 429 || echo "none: $CODES")"
check "sad throttle message" "Too Many Requests" "$(jget "$WORK/body" message)"
sleep 3
check "happy throttle recovers" 200 "$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items")"

echo "== quota (4 per day, offset 1 leaves 3 in the first period) =="
mint "$ADMIN" "$PLAN_CAP" "capped-${TS}"
CODES=""
for _ in 1 2 3 4; do CODES+="$(req -H "x-api-key: ${KVAL}" "${BASE}/v1/items") "; sleep 0.2; done
check "quota: 3 allowed then limited" "200 200 200 429 " "$CODES"
check "sad quota message" "Limit Exceeded" "$(jget "$WORK/body" message)"

echo "== IAM on apigateway key APIs =="
mint "$ADMIN_DENIED" "$PLAN_STD" "denied-${TS}"
check "sad role without POST /apikeys" "AccessDenied" "$(jget "$WORK/mint.json" error)" "$(cat "$WORK/mint.json")"
check "sad denied mint created no key" "0" "$(aws apigateway get-api-keys --name-query "denied-${TS}" --query 'length(items)' --output text)"

echo "== apiKeySource AUTHORIZER =="
fn_uri() { echo "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT}:function:$1/invocations"; }
AUTHORIZER_URI="$(fn_uri "$AUTHZ")" HANDLER_URI="$(fn_uri "$HANDLER")" \
	python3 -c 'import os,sys; t=open(sys.argv[1]).read(); print(t.replace("${AUTHORIZER_URI}", os.environ["AUTHORIZER_URI"]).replace("${HANDLER_URI}", os.environ["HANDLER_URI"]))' \
	"$SLICE/openapi-authorizer.template.json" >"$WORK/openapi-authorizer.json"
API2_ID="$(aws apigateway import-rest-api --body "fileb://${WORK}/openapi-authorizer.json" --query id --output text)"
for fn in "$HANDLER" "$AUTHZ"; do
	aws lambda add-permission --function-name "$fn" --statement-id "apigw2-${TS}" --action lambda:InvokeFunction \
		--principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API2_ID}/*" >/dev/null
done
aws apigateway create-deployment --rest-api-id "$API2_ID" --stage-name local >/dev/null
BASE2="${EP}/restapis/${API2_ID}/local/_user_request_"
check "happy apiKeySource imported" "AUTHORIZER" "$(aws apigateway get-rest-api --rest-api-id "$API2_ID" --query apiKeySource --output text)"
P_AUTH="$(mk_plan_for "$API2_ID" "$PLAN_AUTHZ" --throttle rateLimit=50,burstLimit=100)"
PLAN_IDS+=("$P_AUTH")
mint "$ADMIN" "$PLAN_AUTHZ" "authz-${TS}"
check "happy authorizer usageIdentifierKey" 200 "$(req -H "Authorization: Bearer ${KVAL}" "${BASE2}/v1/items")" "$(cat "$WORK/body")"
check "sad authorizer unknown key" 403 "$(req -H "Authorization: Bearer nope-${TS}" "${BASE2}/v1/items")"
check "sad authorizer header x-api-key ignored" 403 "$(req -H "Authorization: Bearer nope-${TS}" -H "x-api-key: ${KVAL}" "${BASE2}/v1/items")"

[[ "$FAIL" == "0" ]] || exit 1
echo "OK: REST API keys + usage plans (${API_ID})"
