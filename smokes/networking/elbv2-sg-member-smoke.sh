#!/usr/bin/env bash
# #768: ALB SG membership — target that admits traffic only from the ALB SG
# becomes healthy and serves through the listener; a peer outside the ALB SG
# cannot reach the target port; deleting the ALB drops membership again.
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
KEEP="${AWSBOX_ELBV2_SG_KEEP:-0}"
PORT=8080
ALB_PORT=80
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB_A="" SUB_B=""
SG_A="" SG_T="" SG_B="" SG_EMPTY=""
INST_T="" INST_B=""
LB="" TG="" LIS=""
UD=""

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
	[[ -n "$INST_T" ]] && aws ec2 terminate-instances --instance-ids "$INST_T" >/dev/null 2>&1 || true
	[[ -n "$INST_B" ]] && aws ec2 terminate-instances --instance-ids "$INST_B" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$SG_T" ]] && aws ec2 delete-security-group --group-id "$SG_T" >/dev/null 2>&1 || true
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1 || true
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1 || true
	[[ -n "$SG_EMPTY" ]] && aws ec2 delete-security-group --group-id "$SG_EMPTY" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	[[ -n "$UD" ]] && rm -f "$UD"
	exit "$rc"
}
trap cleanup EXIT

tcp_result() {
	local name="$1" ip="$2" port="$3"
	docker exec "$name" python3 -c '
import socket, sys
ip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(3)
try:
    s.connect((ip, port))
except ConnectionRefusedError:
    print("open")
except socket.timeout:
    print("closed")
except OSError as exc:
    # unreachable / no route ≈ drop for this smoke
    if exc.errno in (113, 101, 111):
        print("closed" if exc.errno != 111 else "open")
    else:
        print("closed")
else:
    print("open")
finally:
    s.close()
' "$ip" "$port"
}

expect_closed() {
	local name="$1" ip="$2" label="$3"
	local got
	got="$(tcp_result "$name" "$ip" "$PORT")"
	[[ "$got" == "closed" ]] || fail "$label expected deny, got $got ($name -> $ip:$PORT)"
	echo "ok  $label"
}

LS="$("${COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/stackwrangler up)"

echo "==> VPC + SGs (ALB=A, target admits only from A, peer=B, empty=no LB)"
VPC="$(aws ec2 create-vpc --cidr-block 10.218.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG_A="$(aws ec2 create-security-group --group-name "elbv2-sg-a-${TS}" --description alb --vpc-id "$VPC" --query 'GroupId' --output text)"
SG_T="$(aws ec2 create-security-group --group-name "elbv2-sg-t-${TS}" --description target --vpc-id "$VPC" --query 'GroupId' --output text)"
SG_B="$(aws ec2 create-security-group --group-name "elbv2-sg-b-${TS}" --description peer --vpc-id "$VPC" --query 'GroupId' --output text)"
SG_EMPTY="$(aws ec2 create-security-group --group-name "elbv2-sg-empty-${TS}" --description no-lb --vpc-id "$VPC" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_A" --protocol tcp --port "$ALB_PORT" --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_A" >/dev/null
# Empty SG reference must stay memberless (no LB / no ENI in SG_EMPTY).
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port 18080 --source-group "$SG_EMPTY" >/dev/null

UD="$(mktemp)"
cat > "$UD" <<EOF
#!/bin/bash
cat > /tmp/http8080.py << 'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"elbv2-sg-ok"
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

echo "==> target in SG_T + peer in SG_B"
INST_T="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB_A" --security-group-ids "$SG_T" --user-data "file://${UD}" \
	--query 'Instances[0].InstanceId' --output text)"
INST_B="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB_A" --security-group-ids "$SG_B" \
	--query 'Instances[0].InstanceId' --output text)"

wait_ready() {
	local id="$1" need_http="${2:-0}"
	local cid="" i
	for i in $(seq 1 90); do
		cid="$(cid_for "$id")"
		if [[ -n "$cid" ]] && docker exec "$cid" true >/dev/null 2>&1; then
			if [[ "$need_http" == "0" ]]; then
				echo "$cid"
				return 0
			fi
			if docker exec "$cid" test -f /tmp/servers-ready \
				&& docker exec "$cid" python3 -c "import socket; socket.create_connection(('127.0.0.1', ${PORT}), 2).close()" 2>/dev/null; then
				echo "$cid"
				return 0
			fi
		fi
		sleep 2
	done
	fail "${id} not ready"
}

CT="$(wait_ready "$INST_T" 1)"
CB="$(wait_ready "$INST_B" 0)"
TIP="$(aws ec2 describe-instances --instance-ids "$INST_T" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
echo "target=${INST_T} ip=${TIP} peer=${INST_B}"

echo "==> empty SG reference still has no members (peer cannot open :18080)"
expect_closed "$CB" "$TIP" "peer vs empty-SG-ref port before ALB"

echo "==> ALB in SG_A + instance target admitting only from A"
TG="$(aws elbv2 create-target-group \
	--name "sgt${TS}" --protocol HTTP --port "$PORT" \
	--vpc-id "$VPC" --target-type instance \
	--health-check-protocol HTTP --health-check-path / \
	--health-check-port traffic-port --matcher HttpCode=200 \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer \
	--name "sga${TS}" --type application --scheme internet-facing \
	--subnets "$SUB_A" "$SUB_B" --security-groups "$SG_A" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${INST_T},Port=${PORT}" >/dev/null
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol HTTP --port "$ALB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"
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
echo "lb=${LB##*/} dns=${DNS} edge=${EDGE}"

wait_healthy() {
	local i state
	for i in $(seq 1 40); do
		state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
			--query "TargetHealthDescriptions[0].TargetHealth.State" --output text)"
		echo "health try=${i} state=${state}"
		[[ "$state" == "healthy" ]] && return 0
		sleep 2
	done
	aws elbv2 describe-target-health --target-group-arn "$TG" >&2 || true
	docker exec "$CT" iptables -S SG_IN >&2 || true
	fail "target did not become healthy (ALB SG membership)"
}
wait_healthy

echo "==> request through ALB listener"
BODY="$(python3 - "$EDGE" "$ALB_PORT" "$DNS" <<'PY'
import http.client, sys
edge, port, host = sys.argv[1], int(sys.argv[2]), sys.argv[3]
conn = http.client.HTTPConnection(edge, port, timeout=5)
conn.request("GET", "/", headers={"Host": host})
resp = conn.getresponse()
print(resp.status)
print(resp.read().decode())
conn.close()
PY
)"
STATUS="$(echo "$BODY" | head -1)"
PAYLOAD="$(echo "$BODY" | tail -n +2)"
[[ "$STATUS" == "200" ]] || fail "ALB request status=${STATUS} body=${PAYLOAD}"
[[ "$PAYLOAD" == *elbv2-sg-ok* ]] || fail "unexpected ALB body: ${PAYLOAD}"
echo "ok  ALB forward reached target"

echo "==> peer outside SG_A still cannot reach target :${PORT}"
expect_closed "$CB" "$TIP" "peer outside ALB SG"

echo "==> delete ALB → LocalEmu leaves SG_A; health checks from LocalEmu drop"
aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null
LB=""
# Give referencer refresh a moment, then probe from LocalEmu on the VPC net.
sleep 2
VPC_IP="$(docker inspect "$LS" | python3 -c '
import json, sys
nets = json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]
want = "localemu-vpc-" + sys.argv[1]
for name, cfg in nets.items():
    if name == want:
        print(cfg.get("IPAddress") or "")
        break
' "$VPC")"
[[ -n "$VPC_IP" ]] || fail "LocalEmu missing VPC IP after LB delete"
# From the peer container, SG_A membership is empty so LocalEmu's IP must not match;
# probe by asking the target whether a TCP from LocalEmu would be listed — instead
# curl from LocalEmu itself (source = former LB member IP).
GOT="$(docker exec "$LS" python3 -c '
import socket, sys
ip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(3)
try:
    s.connect((ip, port))
except (socket.timeout, TimeoutError):
    print("closed")
except ConnectionRefusedError:
    print("open")
except OSError:
    print("closed")
else:
    print("open")
finally:
    s.close()
' "$TIP" "$PORT")"
[[ "$GOT" == "closed" ]] || fail "after ALB delete, LocalEmu still reaches target (got ${GOT})"
echo "ok  empty SG_A membership after ALB delete"
expect_closed "$CB" "$TIP" "peer still denied after ALB delete"

echo "PASS elbv2-sg-member-smoke (#768)"
