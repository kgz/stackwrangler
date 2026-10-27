#!/usr/bin/env bash
# VPC route enforcement (#204).
# - Private subnet with no 0.0.0.0/0 cannot reach a public host.
# - The same workload can, through an HTTP proxy reached over peering.
# - Peering both ways; deleting one route breaks that direction.
# - A NAT gateway route restores direct egress.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_VPC_ROUTING_KEEP:-0}"
PUB_IP="203.0.113.10"
WORKDIR=""
SERVER_PID=""
ADDED_IP=0
VPC_A="" VPC_B="" SUB_A="" SUB_B="" SG_A="" SG_B=""
PCX="" NAT_B="" NAT_A="" ALLOC_B="" ALLOC_A=""
INST_A="" INST_B=""

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
	[[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"
	if [[ "$ADDED_IP" == "1" ]]; then
		sudo -n ip addr del "${PUB_IP}/32" dev lo 2>/dev/null || true
	fi
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$INST_A" ]] && aws ec2 terminate-instances --instance-ids "$INST_A" >/dev/null 2>&1 || true
	[[ -n "$INST_B" ]] && aws ec2 terminate-instances --instance-ids "$INST_B" >/dev/null 2>&1 || true
	[[ -n "$NAT_A" ]] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_A" >/dev/null 2>&1 || true
	[[ -n "$NAT_B" ]] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_B" >/dev/null 2>&1 || true
	[[ -n "$PCX" ]] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$ALLOC_A" ]] && aws ec2 release-address --allocation-id "$ALLOC_A" >/dev/null 2>&1 || true
	[[ -n "$ALLOC_B" ]] && aws ec2 release-address --allocation-id "$ALLOC_B" >/dev/null 2>&1 || true
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1 || true
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC_A" ]] && aws ec2 delete-vpc --vpc-id "$VPC_A" >/dev/null 2>&1 || true
	[[ -n "$VPC_B" ]] && aws ec2 delete-vpc --vpc-id "$VPC_B" >/dev/null 2>&1 || true
}
trap cleanup EXIT

reach() {
	local iid="$1" url="$2" want="${3:-}"
	local out
	if ! out="$(docker exec "localemu-ec2-${iid}" curl -sS --max-time 4 "$url" 2>/dev/null)"; then
		return 1
	fi
	if [[ -n "$want" && "$out" != *"$want"* ]]; then
		printf '%s\n' "$out" >&2
		return 1
	fi
	return 0
}

dump_net() {
	local iid="$1"
	echo "---- routes ${iid} ----" >&2
	docker exec "localemu-ec2-${iid}" ip route >&2 || true
	echo "---- mangle ${iid} ----" >&2
	docker exec "localemu-ec2-${iid}" iptables -t mangle -S AWSBOX-RT >&2 || true
	echo "---- http log ${iid} ----" >&2
	docker exec "localemu-ec2-${iid}" cat /var/log/awsbox-httpd.log >&2 || true
}

if ! ip -4 addr show dev lo | grep -q "${PUB_IP}/"; then
	sudo -n ip addr add "${PUB_IP}/32" dev lo
	ADDED_IP=1
fi

WORKDIR="$(mktemp -d)"
printf 'public-ok\n' > "${WORKDIR}/index.html"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("'"${PUB_IP}"'", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind "$PUB_IP" --directory "$WORKDIR" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 0.2
curl -sf --max-time 2 "http://${PUB_IP}:${PORT}/" | grep -q 'public-ok' || {
	echo "FAIL: public host ${PUB_IP}:${PORT} not reachable from this shell" >&2
	exit 1
}

mkdir -p "$ROOT/.awsbox"
cat > "$ROOT/.awsbox/vpc-routing-httpd.py" <<'PY'
import os
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/fetch":
            url = (urllib.parse.parse_qs(parsed.query).get("url") or [""])[0]
            try:
                with urllib.request.urlopen(url, timeout=3) as resp:
                    body = resp.read()
                    code = resp.status
            except Exception as exc:
                body = str(exc).encode()
                code = 502
        else:
            body = os.environ.get("AWSBOX_HELLO", "ok").encode()
            code = 200
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PY

write_ud() {
	local hello="$1" dest="$2"
	{
		echo '#!/bin/sh'
		echo 'mkdir -p /var/lib/localemu'
		echo "cat > /var/lib/localemu/awsbox-httpd.py << 'PY'"
		cat "$ROOT/.awsbox/vpc-routing-httpd.py"
		echo 'PY'
		echo "nohup env AWSBOX_HELLO=${hello} python3 /var/lib/localemu/awsbox-httpd.py >/var/log/awsbox-httpd.log 2>&1 &"
		echo 'exit 0'
	} > "$dest"
}
write_ud instance-a-ok "$ROOT/.awsbox/vpc-routing-a.sh"
write_ud proxy-ok "$ROOT/.awsbox/vpc-routing-b.sh"

VPC_A="$(aws ec2 create-vpc --cidr-block 10.204.0.0/16 --query Vpc.VpcId --output text)"
VPC_B="$(aws ec2 create-vpc --cidr-block 198.51.100.0/24 --query Vpc.VpcId --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.204.1.0/24 --query Subnet.SubnetId --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block 198.51.100.0/26 --query Subnet.SubnetId --output text)"
SG_A="$(aws ec2 create-security-group --group-name "awsbox-rt-a-${TS}" --description awsbox-vpc-routing --vpc-id "$VPC_A" --query GroupId --output text)"
SG_B="$(aws ec2 create-security-group --group-name "awsbox-rt-b-${TS}" --description awsbox-vpc-routing --vpc-id "$VPC_B" --query GroupId --output text)"
for sg in "$SG_A" "$SG_B"; do
	aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
done

PCX="$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_A" --peer-vpc-id "$VPC_B" --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)"
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null

rt_main() {
	aws ec2 describe-route-tables \
		--filters "Name=vpc-id,Values=$1" "Name=association.main,Values=true" \
		--query 'RouteTables[0].RouteTableId' --output text
}
RT_A="$(rt_main "$VPC_A")"
RT_B="$(rt_main "$VPC_B")"

ALLOC_B="$(aws ec2 allocate-address --query AllocationId --output text)"
NAT_B="$(aws ec2 create-nat-gateway --subnet-id "$SUB_B" --allocation-id "$ALLOC_B" --query 'NatGateway.NatGatewayId' --output text)"
aws ec2 create-route --route-table-id "$RT_B" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_B" >/dev/null
aws ec2 create-route --route-table-id "$RT_A" --destination-cidr-block 198.51.100.0/24 --vpc-peering-connection-id "$PCX" >/dev/null
aws ec2 create-route --route-table-id "$RT_B" --destination-cidr-block 10.204.0.0/16 --vpc-peering-connection-id "$PCX" >/dev/null

INST_A="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB_A" --security-group-ids "$SG_A" \
	--user-data "file://${ROOT}/.awsbox/vpc-routing-a.sh" \
	--query 'Instances[0].InstanceId' --output text)"
INST_B="$(aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
	--subnet-id "$SUB_B" --security-group-ids "$SG_B" \
	--user-data "file://${ROOT}/.awsbox/vpc-routing-b.sh" \
	--query 'Instances[0].InstanceId' --output text)"

for iid in "$INST_A" "$INST_B"; do
	ok=0
	for _ in $(seq 1 45); do
		state="$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text)"
		if [[ "$state" == "running" ]] && reach "$iid" "http://127.0.0.1/"; then
			ok=1
			break
		fi
		sleep 2
	done
	[[ "$ok" == "1" ]] || {
		echo "FAIL: ${iid} http server not up (state=${state:-})" >&2
		dump_net "$iid"
		exit 1
	}
done

IP_A="$(aws ec2 describe-instances --instance-ids "$INST_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
IP_B="$(aws ec2 describe-instances --instance-ids "$INST_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
echo "A=${INST_A} ${IP_A}  B=${INST_B} ${IP_B}  public=http://${PUB_IP}:${PORT}/"

if reach "$INST_A" "http://${PUB_IP}:${PORT}/" public-ok; then
	echo "FAIL: private subnet reached public host without a default route" >&2
	dump_net "$INST_A"
	exit 1
fi
echo "ok  private subnet blocked from public host"

if ! reach "$INST_A" "http://${IP_B}/fetch?url=http%3A%2F%2F${PUB_IP}%3A${PORT}%2F" public-ok; then
	echo "FAIL: private subnet could not reach public host via peering proxy" >&2
	dump_net "$INST_A"
	dump_net "$INST_B"
	exit 1
fi
echo "ok  public host via HTTP proxy over peering"

if ! reach "$INST_A" "http://${IP_B}/" proxy-ok; then
	echo "FAIL: A cannot reach B over peering" >&2
	dump_net "$INST_A"
	exit 1
fi
if ! reach "$INST_B" "http://${IP_A}/" instance-a-ok; then
	echo "FAIL: B cannot reach A over peering" >&2
	dump_net "$INST_B"
	exit 1
fi
echo "ok  peering both ways"

aws ec2 delete-route --route-table-id "$RT_A" --destination-cidr-block 198.51.100.0/24 >/dev/null
sleep 1
if reach "$INST_A" "http://${IP_B}/" proxy-ok; then
	echo "FAIL: A still reaches B after its peering route was removed" >&2
	dump_net "$INST_A"
	exit 1
fi
if ! reach "$INST_B" "http://${IP_A}/" instance-a-ok; then
	echo "FAIL: B lost its route to A when only A's route was removed" >&2
	dump_net "$INST_B"
	exit 1
fi
echo "ok  removing one peering route breaks that direction"

ALLOC_A="$(aws ec2 allocate-address --query AllocationId --output text)"
NAT_A="$(aws ec2 create-nat-gateway --subnet-id "$SUB_A" --allocation-id "$ALLOC_A" --query 'NatGateway.NatGatewayId' --output text)"
aws ec2 create-route --route-table-id "$RT_A" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_A" >/dev/null
sleep 1
if ! reach "$INST_A" "http://${PUB_IP}:${PORT}/" public-ok; then
	echo "FAIL: NAT route did not restore egress" >&2
	dump_net "$INST_A"
	exit 1
fi
echo "ok  NAT gateway route restores egress"

rm -f "$ROOT/.awsbox/vpc-routing-httpd.py" "$ROOT/.awsbox/vpc-routing-a.sh" "$ROOT/.awsbox/vpc-routing-b.sh"
echo "OK: vpc routing (${INST_A} / ${INST_B})"
