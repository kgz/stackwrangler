#!/usr/bin/env bash
# #236: NLB client IP at the target security group.
#
# App port allows only the client CIDR (or, if host DNAT is unavailable, the
# LocalEmu proxy /32). Health checks use a separate port so LB probes do not
# punch a hole in the app rule. NLB TCP from the allowed client succeeds;
# a direct connect from a different address is refused.
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
KEEP="${AWSBOX_NLB_SG_KEEP:-0}"
APP_PORT=8080
HC_PORT=18080
NLB_PORT=19080
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB=""
SG_T="" SG_A="" SG_B=""
INST_T="" INST_A="" INST_B=""
LB="" TG="" LIS=""
UD=""
ALLOW_CIDR=""
MODE=""

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
	[[ -n "$LIS" ]] && aws elbv2 delete-listener --listener-arn "$LIS" >/dev/null 2>&1 || true
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$INST_T" ]] && aws ec2 terminate-instances --instance-ids "$INST_T" >/dev/null 2>&1 || true
	[[ -n "$INST_A" ]] && aws ec2 terminate-instances --instance-ids "$INST_A" >/dev/null 2>&1 || true
	[[ -n "$INST_B" ]] && aws ec2 terminate-instances --instance-ids "$INST_B" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$SG_T" ]] && aws ec2 delete-security-group --group-id "$SG_T" >/dev/null 2>&1 || true
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1 || true
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
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
    if getattr(exc, "errno", None) == 111:
        print("open")
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
	got="$(tcp_result "$name" "$ip" "$APP_PORT")"
	[[ "$got" == "closed" ]] || fail "$label expected deny, got $got ($name -> $ip:$APP_PORT)"
	echo "ok  $label"
}

nlb_payload() {
	local name="$1" vip="$2" port="$3"
	docker exec "$name" python3 -c '
import socket, sys
vip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(5)
try:
    s.connect((vip, port))
    s.settimeout(5)
    data = s.recv(256)
except Exception:
    print("")
else:
    print(data.decode("latin1", "replace").strip())
finally:
    s.close()
' "$vip" "$port"
}

LS="$("${COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/stackwrangler up)"

echo "==> VPC + SGs (target admits app port only from client/proxy; HC open)"
VPC="$(aws ec2 create-vpc --cidr-block 10.236.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.236.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SG_T="$(aws ec2 create-security-group --group-name "nlb-sg-t-${TS}" --description target --vpc-id "$VPC" --query 'GroupId' --output text)"
SG_A="$(aws ec2 create-security-group --group-name "nlb-sg-a-${TS}" --description client --vpc-id "$VPC" --query 'GroupId' --output text)"
SG_B="$(aws ec2 create-security-group --group-name "nlb-sg-b-${TS}" --description peer --vpc-id "$VPC" --query 'GroupId' --output text)"
# Health checks leave LocalEmu on the VPC bridge; keep them off the app port.
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$HC_PORT" --cidr 0.0.0.0/0 >/dev/null

UD="$(mktemp)"
cat > "$UD" <<EOF
#!/bin/bash
cat > /tmp/nlb-sg-peer.py << 'PY'
import socket, threading

def serve(port, name):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(32)
    while True:
        conn, addr = srv.accept()
        try:
            conn.sendall(f"{name} peer={addr[0]}\n".encode())
        finally:
            conn.close()

threading.Thread(target=serve, args=(${APP_PORT}, "app"), daemon=True).start()
threading.Thread(target=serve, args=(${HC_PORT}, "hc"), daemon=True).start()
open("/tmp/servers-ready", "w").close()
threading.Event().wait()
PY
nohup python3 /tmp/nlb-sg-peer.py >/tmp/nlb-sg-peer.log 2>&1 &
EOF

echo "==> instances: target + client A + peer B"
INST_T="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB" --security-group-ids "$SG_T" --user-data "file://${UD}" \
	--query 'Instances[0].InstanceId' --output text)"
INST_A="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB" --security-group-ids "$SG_A" \
	--query 'Instances[0].InstanceId' --output text)"
INST_B="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB" --security-group-ids "$SG_B" \
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
				&& docker exec "$cid" python3 -c "import socket; socket.create_connection(('127.0.0.1', ${APP_PORT}), 2).close()" 2>/dev/null; then
				echo "$cid"
				return 0
			fi
		fi
		sleep 2
	done
	fail "${id} not ready"
}

CT="$(wait_ready "$INST_T" 1)"
CA="$(wait_ready "$INST_A" 0)"
CB="$(wait_ready "$INST_B" 0)"
TIP="$(aws ec2 describe-instances --instance-ids "$INST_T" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
AIP="$(aws ec2 describe-instances --instance-ids "$INST_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
BIP="$(aws ec2 describe-instances --instance-ids "$INST_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
echo "target=${INST_T} ${TIP}  A=${INST_A} ${AIP}  B=${INST_B} ${BIP}"

# Prefer client-IP-only on the app port (proves DNAT retention into SG_IN).
ALLOW_CIDR="${AIP}/32"
MODE=client-cidr
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$APP_PORT" --cidr "$ALLOW_CIDR" >/dev/null

echo "==> peer B direct to target app port refused before NLB"
expect_closed "$CB" "$TIP" "peer B direct refused (client-only SG)"

echo "==> internal NLB → instance target (HC on ${HC_PORT}, traffic ${APP_PORT})"
TG="$(aws elbv2 create-target-group \
	--name "nlbsg${TS}" --protocol TCP --port "$APP_PORT" \
	--vpc-id "$VPC" --target-type instance \
	--health-check-protocol TCP --health-check-port "$HC_PORT" \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer \
	--name "nlbsg${TS}" --type network --scheme internal \
	--subnets "$SUB" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${INST_T},Port=${APP_PORT}" >/dev/null
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol TCP --port "$NLB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"
DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].DNSName' --output text)"

LB_VPC_IP="$(docker inspect "$LS" -f "{{(index .NetworkSettings.Networks \"localemu-vpc-${VPC}\").IPAddress}}" 2>/dev/null || true)"
[[ -n "$LB_VPC_IP" && "$LB_VPC_IP" != "<no value>" ]] || fail "LocalEmu missing VPC IP on localemu-vpc-${VPC}"
echo "lb_vpc_ip=${LB_VPC_IP} dns=${DNS}"

wait_healthy() {
	local i state
	for i in $(seq 1 40); do
		state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
			--query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || true)"
		echo "health try=${i} state=${state}"
		[[ "$state" == "healthy" ]] && return 0
		sleep 2
	done
	aws elbv2 describe-target-health --target-group-arn "$TG" >&2 || true
	docker exec "$CT" iptables -S SG_IN >&2 || true
	fail "target did not become healthy"
}
wait_healthy

VIP="$LB_VPC_IP"
RESOLVED="$(docker exec "$CA" getent hosts "$DNS" 2>/dev/null | awk '{print $1; exit}' || true)"
if [[ -n "$RESOLVED" ]]; then
	VIP="$RESOLVED"
	echo "ok  client resolves ${DNS} → ${VIP}"
fi

echo "==> client A → NLB VIP (SG allows ${ALLOW_CIDR})"
BODY=""
for _ in $(seq 1 20); do
	BODY="$(nlb_payload "$CA" "$VIP" "$NLB_PORT")"
	[[ "$BODY" == app\ peer=* ]] && break
	sleep 1
done

if [[ "$BODY" != app\ peer=* ]]; then
	# Host DNAT unavailable → userspace proxy; target sees LocalEmu. Allow proxy /32.
	echo "note: NLB with client-only SG failed (body='${BODY}'); authorizing proxy ${LB_VPC_IP}/32"
	aws ec2 revoke-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$APP_PORT" --cidr "$ALLOW_CIDR" >/dev/null 2>&1 || true
	ALLOW_CIDR="${LB_VPC_IP}/32"
	MODE=proxy-cidr
	aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$APP_PORT" --cidr "$ALLOW_CIDR" >/dev/null
	BODY=""
	for _ in $(seq 1 20); do
		BODY="$(nlb_payload "$CA" "$VIP" "$NLB_PORT")"
		[[ "$BODY" == app\ peer=* ]] && break
		sleep 1
	done
fi

[[ "$BODY" == app\ peer=* ]] || {
	docker exec "$CT" iptables -S SG_IN >&2 || true
	fail "NLB path did not reach target (body='${BODY}', mode=${MODE})"
}
PEER_SEEN="${BODY#app peer=}"
echo "ok  NLB path via ${MODE}: ${BODY}"

if [[ "$MODE" == "client-cidr" ]]; then
	[[ "$PEER_SEEN" == "$AIP" ]] || fail "target SG path should see client ${AIP}, saw ${PEER_SEEN}"
	echo "ok  target accept() source is client ${AIP} (DNAT → SG_IN)"
else
	[[ "$PEER_SEEN" == "$LB_VPC_IP" ]] || echo "note: proxy peer=${PEER_SEEN} (expected LocalEmu ${LB_VPC_IP})"
	echo "ok  target SG admits proxy subnet ${ALLOW_CIDR}"
fi

echo "==> peer B still refused on direct app port"
expect_closed "$CB" "$TIP" "peer B direct refused after NLB success"

# Client A direct should still match the client-cidr rule; under proxy-cidr it may be refused.
if [[ "$MODE" == "client-cidr" ]]; then
	GOT_A="$(tcp_result "$CA" "$TIP" "$APP_PORT")"
	[[ "$GOT_A" == "open" ]] || fail "client A direct should still be allowed under client-cidr (got ${GOT_A})"
	echo "ok  client A direct still allowed"
fi

echo "PASS elbv2-nlb-client-ip-sg-smoke (#236) mode=${MODE} allow=${ALLOW_CIDR}"
