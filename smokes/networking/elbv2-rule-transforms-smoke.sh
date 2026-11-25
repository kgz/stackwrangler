#!/usr/bin/env bash
# #766: ALB listener-rule url-rewrite / host-header-rewrite Transforms
# round-trip on DescribeRules, apply before forward, ResetTransforms clears.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
KEEP="${AWSBOX_ELBV2_XF_KEEP:-0}"
PORT=8080
ALB_PORT=8088
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB_A="" SUB_B="" SG="" INST="" LB="" TG="" LIS="" RULE="" UD=""

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cid_for() {
	docker ps -q --filter "label=localemu.instance-id=$1" | head -1
}

cleanup() {
	local rc=$?
	set +e
	if [[ "$KEEP" == "1" ]]; then
		echo "KEEP=1; leaving resources (exit $rc)"
		exit "$rc"
	fi
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$INST" ]] && aws ec2 terminate-instances --instance-ids "$INST" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	[[ -n "$UD" ]] && rm -f "$UD"
	exit "$rc"
}
trap cleanup EXIT

# Internal ALB binds the VPC address only — dial LocalEmu on localemu-vpc-*.
http_req() {
	local path="$1"
	local host="${2:-$DNS}"
	local ip out
	ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "$LS")"
	[[ -n "$ip" ]] || fail "no LocalEmu IP on ${NET}"
	out="$(docker run --rm --network "$NET" curlimages/curl:8.5.0 \
		-sS --max-time 10 -w '\n%{http_code}' -H "Host: ${host}" \
		"http://${ip}:${ALB_PORT}${path}" || true)"
	# curl -w appends status on its own line after the body
	local status body
	status="$(echo "$out" | tail -n1)"
	body="$(echo "$out" | sed '$d')"
	echo "$status"
	echo "$body"
}

# AWS CLI packages often lag botocore on Transforms (Oct 2025). Use boto3.
elbv2_py() {
	python3 - "$EP" "$REGION" "$KEY" "$SECRET" "$@" <<'PY'
import json, sys
import boto3

ep, region, key, secret = sys.argv[1:5]
op = sys.argv[5]
args = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {}
client = boto3.client(
    "elbv2",
    endpoint_url=ep,
    region_name=region,
    aws_access_key_id=key,
    aws_secret_access_key=secret,
)
out = getattr(client, op)(**args)
print(json.dumps(out, default=str))
PY
}

LS="$("${COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/stackwrangler up)"

echo "==> VPC + echo target (path + Host)"
VPC="$(aws ec2 create-vpc --cidr-block 10.218.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "elbv2-xf-${TS}" --description xf --vpc-id "$VPC" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$ALB_PORT" --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 >/dev/null

UD="$(mktemp)"
cat > "$UD" <<EOF
#!/bin/bash
cat > /tmp/http8080.py << 'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "")
        body = ("echo path=" + self.path + ";host=" + host).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        return

ThreadingHTTPServer(("0.0.0.0", ${PORT}), H).serve_forever()
PY
nohup python3 /tmp/http8080.py >/tmp/http8080.log 2>&1 &
touch /tmp/servers-ready
EOF

INST="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB_A" --security-group-ids "$SG" --user-data "file://${UD}" \
	--query 'Instances[0].InstanceId' --output text)"

CT=""
for i in $(seq 1 90); do
	CT="$(cid_for "$INST")"
	if [[ -n "$CT" ]] && docker exec "$CT" test -f /tmp/servers-ready \
		&& docker exec "$CT" python3 -c "import socket; socket.create_connection(('127.0.0.1', ${PORT}), 2).close()" 2>/dev/null; then
		break
	fi
	sleep 2
	[[ "$i" == "90" ]] && fail "${INST} not ready"
done

echo "==> Internal ALB + fixed-response default + /svc* url-rewrite rule"
TG="$(aws elbv2 create-target-group \
	--name "xft${TS}" --protocol HTTP --port "$PORT" \
	--vpc-id "$VPC" --target-type instance \
	--health-check-protocol HTTP --health-check-path / \
	--health-check-port traffic-port --matcher HttpCode=200 \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer \
	--name "xfa${TS}" --type application --scheme internal \
	--subnets "$SUB_A" "$SUB_B" --security-groups "$SG" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${INST},Port=${PORT}" >/dev/null

LIS_JSON="$(mktemp)"
python3 - "$LIS_JSON" "$LB" "$ALB_PORT" <<'PY'
import json, sys
path, lb, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({
    "LoadBalancerArn": lb,
    "Protocol": "HTTP",
    "Port": port,
    "DefaultActions": [{
        "Type": "fixed-response",
        "FixedResponseConfig": {
            "StatusCode": "404",
            "ContentType": "text/plain",
            "MessageBody": "no-match-404",
        },
    }],
}, open(path, "w"))
PY
LIS="$(aws elbv2 create-listener --cli-input-json "file://${LIS_JSON}" \
	--query 'Listeners[0].ListenerArn' --output text)"
rm -f "$LIS_JSON"

CREATE_ARGS="$(python3 - "$LIS" "$TG" <<'PY'
import json, sys
lis, tg = sys.argv[1], sys.argv[2]
print(json.dumps({
    "ListenerArn": lis,
    "Priority": 10,
    "Conditions": [{
        "Field": "path-pattern",
        "PathPatternConfig": {"Values": ["/svc", "/svc/*"]},
    }],
    "Actions": [{"Type": "forward", "TargetGroupArn": tg}],
    "Transforms": [{
        "Type": "url-rewrite",
        "UrlRewriteConfig": {
            "Rewrites": [{"Regex": "^/svc(/.*)?$", "Replace": "$1"}],
        },
    }],
}))
PY
)"
RULE="$(elbv2_py create_rule "$CREATE_ARGS" | python3 -c "import json,sys; print(json.load(sys.stdin)['Rules'][0]['RuleArn'])")"

DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].DNSName' --output text)"
NET="localemu-vpc-${VPC}"
echo "lb=${LB##*/} dns=${DNS} net=${NET} rule=${RULE##*/}"

echo "==> describe-rules returns url-rewrite transform"
DESC="$(elbv2_py describe_rules "{\"RuleArns\":[\"${RULE}\"]}")"
echo "$DESC" | python3 -c '
import json, sys
rules = json.load(sys.stdin)["Rules"]
assert rules, "no rules"
xf = rules[0].get("Transforms") or []
assert len(xf) == 1 and xf[0].get("Type") == "url-rewrite", xf
rw = ((xf[0].get("UrlRewriteConfig") or {}).get("Rewrites") or [None])[0]
assert rw and rw.get("Regex") == "^/svc(/.*)?$" and rw.get("Replace") == "$1", rw
print("ok describe Transforms")
'

for i in $(seq 1 40); do
	state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
		--query "TargetHealthDescriptions[0].TargetHealth.State" --output text)"
	echo "health try=${i} state=${state}"
	[[ "$state" == "healthy" ]] && break
	sleep 2
	[[ "$i" == "40" ]] && fail "target never healthy"
done

echo "==> url-rewrite: /svc/items?a=1 → /items?a=1; /svc → /"
OUT="$(http_req '/svc/items?a=1')"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '2,$p')"
[[ "$STATUS" == "200" ]] || fail "/svc/items status=${STATUS} body=${BODY}"
[[ "$BODY" == *"echo path=/items?a=1"* ]] || fail "/svc/items unexpected body: ${BODY}"
echo "ok  /svc/items?a=1 → target path=/items?a=1"

OUT="$(http_req /svc)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '2,$p')"
[[ "$STATUS" == "200" ]] || fail "/svc status=${STATUS} body=${BODY}"
[[ "$BODY" == *"echo path=/"* && "$BODY" != *"echo path=/svc"* ]] || fail "/svc unexpected body: ${BODY}"
echo "ok  /svc → target path=/"

echo "==> host-header condition + url-rewrite that does not match leaves path"
elbv2_py create_rule "$(python3 - "$LIS" "$TG" <<'PY'
import json, sys
lis, tg = sys.argv[1], sys.argv[2]
print(json.dumps({
    "ListenerArn": lis,
    "Priority": 20,
    "Conditions": [{
        "Field": "host-header",
        "HostHeaderConfig": {"Values": ["untouched.example"]},
    }],
    "Actions": [{"Type": "forward", "TargetGroupArn": tg}],
    "Transforms": [{
        "Type": "url-rewrite",
        "UrlRewriteConfig": {
            "Rewrites": [{"Regex": "^/only-this$", "Replace": "/rewritten"}],
        },
    }],
}))
PY
)" >/dev/null

OUT="$(http_req /other untouched.example)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '2,$p')"
[[ "$STATUS" == "200" ]] || fail "untouched path status=${STATUS} body=${BODY}"
[[ "$BODY" == *"echo path=/other"* ]] || fail "untouched path rewritten: ${BODY}"
echo "ok  non-matching rewrite regex leaves /other"

echo "==> host-header-rewrite: target sees rewritten Host"
elbv2_py modify_rule "$(python3 - "$RULE" <<'PY'
import json, sys
rule = sys.argv[1]
print(json.dumps({
    "RuleArn": rule,
    "Transforms": [
        {
            "Type": "url-rewrite",
            "UrlRewriteConfig": {
                "Rewrites": [{"Regex": "^/svc(/.*)?$", "Replace": "$1"}],
            },
        },
        {
            "Type": "host-header-rewrite",
            "HostHeaderRewriteConfig": {
                "Rewrites": [{"Regex": ".*", "Replace": "app.internal"}],
            },
        },
    ],
}))
PY
)" >/dev/null

OUT="$(http_req /svc/z)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '2,$p')"
[[ "$STATUS" == "200" ]] || fail "host rewrite status=${STATUS} body=${BODY}"
[[ "$BODY" == *"echo path=/z"* ]] || fail "host rewrite path: ${BODY}"
[[ "$BODY" == *"host=app.internal"* ]] || fail "host rewrite Host: ${BODY}"
echo "ok  Host rewritten to app.internal"

echo "==> ResetTransforms clears transform on describe + forward uses original path"
elbv2_py modify_rule "$(python3 - "$RULE" <<'PY'
import json, sys
print(json.dumps({"RuleArn": sys.argv[1], "ResetTransforms": True}))
PY
)" >/dev/null
DESC2="$(elbv2_py describe_rules "{\"RuleArns\":[\"${RULE}\"]}")"
echo "$DESC2" | python3 -c '
import json, sys
rules = json.load(sys.stdin)["Rules"]
xf = rules[0].get("Transforms") or []
assert xf == [], xf
print("ok describe after ResetTransforms empty")
'

OUT="$(http_req /svc/items)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '2,$p')"
[[ "$STATUS" == "200" ]] || fail "after reset status=${STATUS} body=${BODY}"
[[ "$BODY" == *"echo path=/svc/items"* ]] || fail "after reset still rewriting: ${BODY}"
echo "ok  after ResetTransforms target sees /svc/items"

echo "PASS elbv2-rule-transforms-smoke (#766)"
