#!/usr/bin/env bash
# #767: ALB listener with fixed-response (or redirect) default still binds;
# path forward rules work; ModifyListener swaps default without rebinding.
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
KEEP="${AWSBOX_ELBV2_NONFWD_KEEP:-0}"
PORT=8080
ALB_PORT=8087
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB_A="" SUB_B="" SG="" INST="" LB="" TG="" LIS="" UD=""

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

http_req() {
	local path="$1"
	python3 - "$EDGE" "$ALB_PORT" "$DNS" "$path" <<'PY'
import http.client, sys
edge, port, host, path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
conn = http.client.HTTPConnection(edge, port, timeout=5)
conn.request("GET", path, headers={"Host": host})
resp = conn.getresponse()
body = resp.read().decode()
loc = resp.getheader("Location") or ""
print(resp.status)
print(loc)
print(body)
conn.close()
PY
}

LS="$("${COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/stackwrangler up)"

echo "==> VPC + instance target"
VPC="$(aws ec2 create-vpc --cidr-block 10.217.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "elbv2-nonfwd-${TS}" --description nonfwd --vpc-id "$VPC" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$ALB_PORT" --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 >/dev/null

UD="$(mktemp)"
cat > "$UD" <<EOF
#!/bin/bash
cat > /tmp/http8080.py << 'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("svc-ok:" + self.path).encode()
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

echo "==> ALB with fixed-response 404 default + /svc/* forward rule"
TG="$(aws elbv2 create-target-group \
	--name "nft${TS}" --protocol HTTP --port "$PORT" \
	--vpc-id "$VPC" --target-type instance \
	--health-check-protocol HTTP --health-check-path / \
	--health-check-port traffic-port --matcher HttpCode=200 \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer \
	--name "nfa${TS}" --type application --scheme internet-facing \
	--subnets "$SUB_A" "$SUB_B" --security-groups "$SG" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${INST},Port=${PORT}" >/dev/null

# Fixed-response default — this used to skip binding the socket (#767).
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

aws elbv2 create-rule --listener-arn "$LIS" --priority 10 \
	--conditions '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/svc/*"]}}]' \
	--actions "Type=forward,TargetGroupArn=${TG}" >/dev/null

DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].DNSName' --output text)"
EDGE="$(docker inspect "$LS" | python3 -c '
import json, sys
nets = json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]
for name, cfg in nets.items():
    if name.startswith("localemu-"):
        continue
    ip = cfg.get("IPAddress") or ""
    if ip:
        print(ip)
        break
')"
[[ -n "$EDGE" ]] || fail "no edge IP on LocalEmu"
echo "lb=${LB##*/} dns=${DNS} edge=${EDGE} listener=${LIS##*/}"

for i in $(seq 1 40); do
	state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
		--query "TargetHealthDescriptions[0].TargetHealth.State" --output text)"
	echo "health try=${i} state=${state}"
	[[ "$state" == "healthy" ]] && break
	sleep 2
	[[ "$i" == "40" ]] && fail "target never healthy"
done

echo "==> /svc/x reaches target; /other returns fixed-response 404"
OUT="$(http_req /svc/x)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '3,$p')"
[[ "$STATUS" == "200" ]] || fail "/svc/x status=${STATUS} body=${BODY}"
[[ "$BODY" == *svc-ok:/svc/x* ]] || fail "/svc/x unexpected body: ${BODY}"
echo "ok  /svc/x → target"

OUT="$(http_req /other)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '3,$p')"
[[ "$STATUS" == "404" ]] || fail "/other status=${STATUS} (want 404) body=${BODY}"
[[ "$BODY" == *no-match-404* ]] || fail "/other unexpected body: ${BODY}"
echo "ok  /other → fixed-response 404"

echo "==> ModifyListener → redirect default (no rebind)"
MOD_JSON="$(mktemp)"
python3 - "$MOD_JSON" "$LIS" <<'PY'
import json, sys
path, lis = sys.argv[1], sys.argv[2]
json.dump({
    "ListenerArn": lis,
    "DefaultActions": [{
        "Type": "redirect",
        "RedirectConfig": {
            "Protocol": "HTTP",
            "Port": "80",
            "Host": "example.invalid",
            "Path": "/landed",
            "Query": "",
            "StatusCode": "HTTP_301",
        },
    }],
}, open(path, "w"))
PY
aws elbv2 modify-listener --cli-input-json "file://${MOD_JSON}" >/dev/null
rm -f "$MOD_JSON"

OUT="$(http_req /other)"
STATUS="$(echo "$OUT" | sed -n '1p')"
LOC="$(echo "$OUT" | sed -n '2p')"
[[ "$STATUS" == "301" || "$STATUS" == "302" ]] || fail "redirect status=${STATUS}"
[[ "$LOC" == *"example.invalid"* ]] || fail "redirect Location missing host: ${LOC}"
[[ "$LOC" == *"/landed"* ]] || fail "redirect Location missing path: ${LOC}"
echo "ok  /other → redirect ${STATUS} Location=${LOC}"

# Forward rule must still work after default change.
OUT="$(http_req /svc/y)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '3,$p')"
[[ "$STATUS" == "200" ]] || fail "/svc/y after redirect-default status=${STATUS}"
[[ "$BODY" == *svc-ok:/svc/y* ]] || fail "/svc/y unexpected body: ${BODY}"
echo "ok  /svc/y still forwards after ModifyListener"

echo "==> ModifyListener → forward default"
aws elbv2 modify-listener --listener-arn "$LIS" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" >/dev/null

OUT="$(http_req /other)"
STATUS="$(echo "$OUT" | sed -n '1p')"
BODY="$(echo "$OUT" | sed -n '3,$p')"
[[ "$STATUS" == "200" ]] || fail "forward-default /other status=${STATUS} body=${BODY}"
[[ "$BODY" == *svc-ok:/other* ]] || fail "forward-default unexpected body: ${BODY}"
echo "ok  /other → default forward target"

echo "PASS elbv2-nonforward-default-smoke (#767)"
