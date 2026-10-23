#!/usr/bin/env bash
# REST API -> VPC link -> internal NLB -> service on ECS (awsvpc task in a private subnet).
# REQUEST Lambda authorizer; HTTP_PROXY routes PATCH /invoices/{n}/paid and
# POST /invoices/{n}/credit-note inject a service token header; the backend (nginx) answers 403 without it.
#
# Phase A, the AWS shape: integration connectionType VPC_LINK, uri http://<nlb dns>/...
#   Expect 200 with the path parameter and injected header at the backend.
# Phase B, fallback while the emulator has no VPC link / NLB data path: same API but the integration
#   points at the backend's published port (connectionType INTERNET). Covers the rest:
#   happy 200 + path param + injected header; no token / Deny -> blocked and the backend sees NOTHING;
#   task stopped -> API 5xx (AWS: 504 timeout / 503 for an NLB with no healthy target).
# Exit 0 only if every expectation (including expected failures) is observed; phase A fails today (see docs/apigw-rest.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
ACCOUNT="000000000000"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
WORK="$ROOT/.awsbox/apigw-nlb-${TS}"
AUTHZ="awsbox-nlb-authz-${TS}"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
CLUSTER="awsbox-nlb-${TS}"
FAMILY="awsbox-orders-api-${TS}"
SVC_TOKEN="svc-secret-${TS}"
VPC="" SUB="" SG="" LB="" TG="" LISTENER="" VPCLINK="" TASK="" API_A="" API_B="" TD=""

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	for api in "$API_A" "$API_B"; do
		[[ -n "$api" ]] && aws apigateway delete-rest-api --rest-api-id "$api" >/dev/null 2>&1 || true
	done
	[[ -n "$VPCLINK" ]] && aws apigateway delete-vpc-link --vpc-link-id "$VPCLINK" >/dev/null 2>&1 || true
	[[ -n "$LISTENER" ]] && aws elbv2 delete-listener --listener-arn "$LISTENER" >/dev/null 2>&1 || true
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$TASK" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$TD" ]] && aws ecs deregister-task-definition --task-definition "$TD" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$AUTHZ" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
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
check_re() {
	local label="$1" re="$2" got="$3"
	if [[ "$got" =~ $re ]]; then
		echo "ok   ${label}: ${got}"
	else
		echo "FAIL ${label}: got ${got}, want match ${re}" >&2
		FAIL=1
	fi
}
req() { curl -s -m 40 -o "$WORK/body" -w '%{http_code}' "$@"; }
body() { tr -d '\n' <"$WORK/body"; }

mkdir -p "$WORK"
python3 - "$ROOT/examples/apigw-rest/authorizer.js" "$WORK/authorizer.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[1], "index.js")
PY

# --- authorizer Lambda ---
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
aws lambda create-function --function-name "$AUTHZ" --runtime nodejs20.x --role "$ROLE_ARN" \
	--handler index.handler --zip-file "fileb://${WORK}/authorizer.zip" >/dev/null
for _ in $(seq 1 60); do
	[[ "$(aws lambda get-function --function-name "$AUTHZ" --query Configuration.State --output text)" == "Active" ]] && break
	sleep 2
done

# --- network + backend on ECS (private subnet, no public IP) ---
VPC="$(aws ec2 create-vpc --cidr-block 10.88.0.0/16 --query Vpc.VpcId --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.88.1.0/24 --query Subnet.SubnetId --output text)"
SG="$(aws ec2 create-security-group --group-name "awsbox-nlb-${TS}" --description "orders-api tasks" --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null

# nginx: 403 unless X-Internal-Token matches; logs one "HIT ..." line per request that reaches it.
NGINX_CONF='log_format m "HIT $request_method $request_uri tok=$http_x_internal_token"; server { listen 8080; access_log /dev/stdout m; location / { if ($http_x_internal_token != "'"${SVC_TOKEN}"'") { return 403 "denied\n"; } return 200 "backend uri=$request_uri method=$request_method tok=$http_x_internal_token\n"; } }'
python3 - "$NGINX_CONF" >"$WORK/containers.json" <<'PY'
import json, sys
cmd = "printf '%s' \"$NGINX_CONF\" > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'"
print(json.dumps([{"name": "web", "image": "nginx:alpine", "essential": True, "memory": 128,
                   "command": ["sh", "-c", cmd], "environment": [{"name": "NGINX_CONF", "value": sys.argv[1]}],
                   "portMappings": [{"containerPort": 8080, "protocol": "tcp"}]}]))
PY
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
TD="$(aws ecs register-task-definition --family "$FAMILY" --requires-compatibilities FARGATE --network-mode awsvpc \
	--cpu 256 --memory 512 --container-definitions "file://${WORK}/containers.json" --query taskDefinition.taskDefinitionArn --output text)"
TASK="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" --launch-type FARGATE \
	--network-configuration "awsvpcConfiguration={subnets=[${SUB}],securityGroups=[${SG}],assignPublicIp=DISABLED}" \
	--query 'tasks[0].taskArn' --output text)"
task_field() {
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --output json | python3 -c '
import json, sys
t = json.load(sys.stdin)["tasks"][0]
ip = next((d["value"] for a in t.get("attachments", []) for d in a["details"] if d["name"] == "privateIPv4Address"), "")
port = next((str(b["hostPort"]) for c in t["containers"] for b in c.get("networkBindings", []) if b.get("hostPort")), "")
print(t["lastStatus"], ip, port)'
}
for _ in $(seq 1 60); do
	read -r STATUS TASK_IP HOST_PORT < <(task_field)
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
[[ "$STATUS" == "RUNNING" ]] || { echo "FAIL backend task not RUNNING (${STATUS})" >&2; exit 1; }
TASK_ID="${TASK##*/}"
CTR="$(docker ps -a --filter "name=-${TASK_ID:0:8}-" --format '{{.Names}}' | head -1)"
[[ -n "$CTR" ]] || { echo "FAIL backend container not found" >&2; exit 1; }
hits() { docker logs "$CTR" 2>&1 | grep -c '^HIT ' || true; }

# The published port is the only host-visible way in; wait for nginx.
for _ in $(seq 1 30); do
	[[ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H "X-Internal-Token: ${SVC_TOKEN}" "http://127.0.0.1:${HOST_PORT}/")" == "200" ]] && break
	sleep 1
done
check "backend direct with token" 200 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "X-Internal-Token: ${SVC_TOKEN}" "http://127.0.0.1:${HOST_PORT}/")"
check "backend direct without token" 403 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/")"
check "task ENI address is inside the subnet CIDR" "yes" \
	"$(python3 -c 'import ipaddress,sys; print("yes" if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network("10.88.1.0/24") else "no")' "$TASK_IP")" \
	"(task reported ${TASK_IP})"

# --- internal NLB -> target group -> task, VPC link ---
LB="$(aws elbv2 create-load-balancer --name "nlb${TS}" --type network --scheme internal --subnets "$SUB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
NLB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].DNSName' --output text)"
TG="$(aws elbv2 create-target-group --name "tg${TS}" --protocol TCP --port 8080 --vpc-id "$VPC" --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${TASK_IP},Port=8080"
LISTENER="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol TCP --port 80 --default-actions "Type=forward,TargetGroupArn=${TG}" --query 'Listeners[0].ListenerArn' --output text)"
VPCLINK="$(aws apigateway create-vpc-link --name "awsbox-nlb-${TS}" --target-arns "$LB" --query id --output text)"
for _ in $(seq 1 30); do
	[[ "$(aws apigateway get-vpc-link --vpc-link-id "$VPCLINK" --query status --output text)" == "AVAILABLE" ]] && break
	sleep 1
done
check "VPC link AVAILABLE" AVAILABLE "$(aws apigateway get-vpc-link --vpc-link-id "$VPCLINK" --query status --output text)"

# --- REST API builder: build_api <name> <base-uri> [vpc] -> api id ---
build_api() {
	local name="$1" base="$2" vpc="${3:-}" api root inv n r method path
	api="$(aws apigateway create-rest-api --name "$name" --query id --output text)"
	root="$(aws apigateway get-resources --rest-api-id "$api" --query 'items[0].id' --output text)"
	local auth
	auth="$(aws apigateway create-authorizer --rest-api-id "$api" --name token --type REQUEST \
		--authorizer-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REGION}:${ACCOUNT}:function:${AUTHZ}/invocations" \
		--identity-source method.request.header.Authorization --authorizer-result-ttl-in-seconds 0 --query id --output text)"
	aws lambda add-permission --function-name "$AUTHZ" --statement-id "apigw-${api}" --action lambda:InvokeFunction \
		--principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${api}/*" >/dev/null
	inv="$(aws apigateway create-resource --rest-api-id "$api" --parent-id "$root" --path-part invoices --query id --output text)"
	n="$(aws apigateway create-resource --rest-api-id "$api" --parent-id "$inv" --path-part '{n}' --query id --output text)"
	for pair in "PATCH:paid" "POST:credit-note"; do
		method="${pair%%:*}" path="${pair##*:}"
		r="$(aws apigateway create-resource --rest-api-id "$api" --parent-id "$n" --path-part "$path" --query id --output text)"
		aws apigateway put-method --rest-api-id "$api" --resource-id "$r" --http-method "$method" \
			--authorization-type CUSTOM --authorizer-id "$auth" --request-parameters method.request.path.n=true >/dev/null
		# AWS static header values are single-quoted inside the mapping.
		local params="{\"integration.request.path.n\":\"method.request.path.n\",\"integration.request.header.X-Internal-Token\":\"'${SVC_TOKEN}'\"}"
		local conn=()
		[[ -n "$vpc" ]] && conn=(--connection-type VPC_LINK --connection-id "$VPCLINK")
		aws apigateway put-integration --rest-api-id "$api" --resource-id "$r" --http-method "$method" \
			--type HTTP_PROXY --integration-http-method "$method" --uri "${base}/invoices/{n}/${path}" \
			--request-parameters "$params" "${conn[@]}" >/dev/null
	done
	aws apigateway create-deployment --rest-api-id "$api" --stage-name local >/dev/null
	echo "$api"
}
stage() { echo "${EP}/restapis/$1/local/_user_request_"; }

# --- Phase A: VPC link + NLB DNS name (the AWS shape) ---
API_A="$(build_api "orders-api-vpclink-${TS}" "http://${NLB_DNS}:80" vpc)"
A="$(stage "$API_A")"
code="$(req -X PATCH -H 'Authorization: Bearer good' "${A}/invoices/42/paid")"
check "A happy PATCH via VPC link + NLB" 200 "$code" "$(body)"
check "A backend got path param and injected token" "backend uri=/invoices/42/paid method=PATCH tok=${SVC_TOKEN}" "$(body)"

# --- Phase B: same routes, integration straight at the published port ---
GW="${AWSBOX_BACKEND_HOST:-$(docker inspect -f '{{range .NetworkSettings.Networks}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' \
	"$(docker ps -q --filter publish=4566 | head -1)" | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)}"
API_B="$(build_api "orders-api-direct-${TS}" "http://${GW}:${HOST_PORT}")"
B="$(stage "$API_B")"

h0="$(hits)"
code="$(req -X PATCH -H 'Authorization: Bearer good' "${B}/invoices/42/paid")"
check "B happy PATCH /invoices/{n}/paid" 200 "$code" "$(body)"
check "B path param + injected token reach backend (PATCH)" "backend uri=/invoices/42/paid method=PATCH tok=${SVC_TOKEN}" "$(body)"
code="$(req -X POST -H 'Authorization: Bearer good' -d '{"amount":5}' "${B}/invoices/7/credit-note")"
check "B happy POST /invoices/{n}/credit-note" 200 "$code" "$(body)"
check "B path param + injected token reach backend (POST)" "backend uri=/invoices/7/credit-note method=POST tok=${SVC_TOKEN}" "$(body)"
check "B backend saw both requests" 2 "$(($(hits) - h0))"

h1="$(hits)"
code="$(req -X PATCH "${B}/invoices/42/paid")"
check "B sad no token" 401 "$code"
code="$(req -X POST -H 'Authorization: Bearer bad' "${B}/invoices/42/credit-note")"
check "B sad Deny authorizer (AWS: 403)" 403 "$code"
check "B blocked requests never reached the backend" 0 "$(($(hits) - h1))"

aws ecs stop-task --cluster "$CLUSTER" --task "$TASK" >/dev/null
for _ in $(seq 1 30); do
	read -r STATUS _ _ < <(task_field)
	[[ "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
check "backend task STOPPED" STOPPED "$STATUS"
code="$(req -X PATCH -H 'Authorization: Bearer good' "${B}/invoices/42/paid")"
check_re "B sad backend down -> API 5xx (AWS: 504, or 503 from an NLB with no healthy target; emulator: 500)" '^5[0-9][0-9]$' "$code"

[[ "$FAIL" == "0" ]] || exit 1
echo "OK: REST API -> VPC link -> NLB -> ECS (${API_A}, ${API_B})"
