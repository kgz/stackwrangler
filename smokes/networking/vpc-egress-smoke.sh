#!/usr/bin/env bash
# VPC gateway endpoints + Lambda route egress (#230).
# Slice: examples/serverless-v3-rest/slices/egress/
# - Private VPC Lambda, no 0.0.0.0/0: public host times out
# - S3 via gateway-endpoint prefix list succeeds only with the route
# - Peer VPC CIDR succeeds over peering
# - IGW/NAT restores public egress
# - Route rules survive docker restart of the Lambda container
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_VPC_EGRESS_KEEP:-0}"
PUB_IP="203.0.113.10"
# Moto S3 managed prefix-list CIDR (com.amazonaws.*.s3)
S3_PL_IP="52.216.1.1"
SLICE="$ROOT/examples/serverless-v3-rest/slices/egress"
WORKDIR=""
SERVER_PID=""
ADDED_IP=0
FAILS=0
VPC_A="" VPC_B="" SUB_A="" SUB_B="" SG_A="" SG_B=""
PCX="" IGW="" RTB_A=""
PEER_CTR="" FN="" BUCKET="" ROLE_NAME="awsbox-lambda-basic"
ZIP=""

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

ok() { echo "ok  $*"; }
bad() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

cleanup() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
	[[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"
	[[ -n "$ZIP" ]] && rm -f "$ZIP"
	if [[ "$ADDED_IP" == "1" ]]; then
		sudo -n ip addr del "${PUB_IP}/32" dev lo 2>/dev/null || true
	fi
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$FN" ]] && aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$BUCKET" ]] && aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	[[ -n "$PEER_CTR" ]] && docker rm -f "$PEER_CTR" >/dev/null 2>&1 || true
	sleep 1
	# delete gateway endpoints in VPC A
	for ep in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_A:-none}" \
		--query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null); do
		[[ -n "$ep" && "$ep" != "None" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" >/dev/null 2>&1 || true
	done
	[[ -n "$PCX" ]] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null 2>&1 || true
	[[ -n "$IGW" && -n "$VPC_A" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A" >/dev/null 2>&1 || true
	[[ -n "$IGW" ]] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" >/dev/null 2>&1 || true
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1 || true
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC_A" ]] && aws ec2 delete-vpc --vpc-id "$VPC_A" >/dev/null 2>&1 || true
	[[ -n "$VPC_B" ]] && aws ec2 delete-vpc --vpc-id "$VPC_B" >/dev/null 2>&1 || true
}
trap cleanup EXIT

invoke() {
	local payload="$1" out
	out="$(mktemp)"
	aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
		--payload "$payload" "$out" >/dev/null
	cat "$out"
	rm -f "$out"
}

# --- public host on lo ---
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

# --- VPCs, peering, peer HTTP instance ---
# Unique /16s so Docker IPAM does not collide with leftover localemu-vpc-* bridges.
OCT_A=$((160 + RANDOM % 40))
OCT_B=$((200 + RANDOM % 40))
while [[ "$OCT_A" == "$OCT_B" ]]; do OCT_B=$((200 + RANDOM % 40)); done
CIDR_A="10.${OCT_A}.0.0/16"
CIDR_B="10.${OCT_B}.0.0/16"
SUB_CIDR_A="10.${OCT_A}.1.0/24"
SUB_CIDR_B="10.${OCT_B}.1.0/24"

VPC_A="$(aws ec2 create-vpc --cidr-block "$CIDR_A" --query Vpc.VpcId --output text)"
VPC_B="$(aws ec2 create-vpc --cidr-block "$CIDR_B" --query Vpc.VpcId --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block "$SUB_CIDR_A" --query Subnet.SubnetId --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block "$SUB_CIDR_B" --query Subnet.SubnetId --output text)"
SG_A="$(aws ec2 create-security-group --group-name "awsbox-egress-a-${TS}" --description awsbox-vpc-egress --vpc-id "$VPC_A" --query GroupId --output text)"
SG_B="$(aws ec2 create-security-group --group-name "awsbox-egress-b-${TS}" --description awsbox-vpc-egress --vpc-id "$VPC_B" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_B" --protocol tcp --port 80 --cidr "$CIDR_A" >/dev/null

RTB_A="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_A" "Name=association.main,Values=true" \
	--query 'RouteTables[0].RouteTableId' --output text)"
RTB_B="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_B" "Name=association.main,Values=true" \
	--query 'RouteTables[0].RouteTableId' --output text)"

PCX="$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_A" --peer-vpc-id "$VPC_B" \
	--query VpcPeeringConnection.VpcPeeringConnectionId --output text)"
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null
aws ec2 create-route --route-table-id "$RTB_A" --destination-cidr-block "$CIDR_B" \
	--vpc-peering-connection-id "$PCX" >/dev/null
aws ec2 create-route --route-table-id "$RTB_B" --destination-cidr-block "$CIDR_A" \
	--vpc-peering-connection-id "$PCX" >/dev/null

# Peer HTTP target: container on VPC B (+ pcx) so Lambda can reach it over
# the peering route without depending on EC2 VM manager.
PEER_CTR="awsbox-peer-httpd-${TS}"
VPC_B_NET="localemu-vpc-${VPC_B}"
PCX_NET="localemu-pcx-${PCX}"
for _ in $(seq 1 30); do
	docker network inspect "$VPC_B_NET" >/dev/null 2>&1 && break
	sleep 1
done
docker network inspect "$VPC_B_NET" >/dev/null 2>&1 || {
	echo "FAIL: VPC B docker network ${VPC_B_NET} missing" >&2
	exit 1
}
docker pull -q python:3.12-alpine >/dev/null
docker run -d --name "$PEER_CTR" --network "$VPC_B_NET" \
	python:3.12-alpine \
	python3 -c 'from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b = b"peer-ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("0.0.0.0", 80), H).serve_forever()' >/dev/null
# Join peering bridge so L3 matches EC2 peer attach.
if docker network inspect "$PCX_NET" >/dev/null 2>&1; then
	docker network connect "$PCX_NET" "$PEER_CTR" >/dev/null 2>&1 || true
fi
PEER_IP="$(docker inspect "$PEER_CTR" --format '{{json .NetworkSettings.Networks}}' \
	| python3 -c "import json,sys; n=json.load(sys.stdin); print((n.get('$VPC_B_NET') or {}).get('IPAddress') or '')")"
[[ -n "$PEER_IP" ]] || { echo "FAIL: no peer container IP on ${VPC_B_NET}" >&2; docker logs "$PEER_CTR" >&2 || true; exit 1; }
echo "peer ${PEER_CTR} at ${PEER_IP} on ${VPC_B_NET}"
for _ in $(seq 1 20); do
	docker exec "$PEER_CTR" python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1/', timeout=2).read().decode())" 2>/dev/null | grep -q peer-ok && break
	sleep 1
done

# --- S3 bucket + Lambda from slice ---
BUCKET="awsbox-egress-${TS}"
aws s3 mb "s3://${BUCKET}" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
# IAM_ENFORCEMENT: allow Put/Get on the smoke bucket.
S3_POL='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:CreateBucket","s3:ListBucket"],"Resource":"*"}]}'
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name awsbox-egress-s3 --policy-document "$S3_POL" >/dev/null

ZIP="$ROOT/.awsbox/vpc-egress-${TS}.zip"
( cd "$SLICE" && zip -q "$ZIP" handler.py )

FN="awsbox-egress-${TS}"
aws lambda create-function --function-name "$FN" --runtime python3.12 --role "$ROLE_ARN" \
	--handler handler.handler --zip-file "fileb://${ZIP}" --timeout 30 \
	--vpc-config "SubnetIds=${SUB_A},SecurityGroupIds=${SG_A}" >/dev/null

for _ in $(seq 1 60); do
	[[ "$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text)" == "Active" ]] && break
	sleep 2
done

# --- (a) public host must time out without default route ---
PAYLOAD_PUBLIC="$(python3 -c "import json; print(json.dumps({'publicUrl':'http://${PUB_IP}:${PORT}/','timeoutMs':2500}))")"
OUT="$(invoke "$PAYLOAD_PUBLIC")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("public",{}).get("ok") is False, d; print("public blocked:", d["public"].get("detail","")[:80])' \
	&& ok "private Lambda cannot reach public host" || bad "public host reachable without default route: $OUT"

# --- S3 via prefix-list IP fails without gateway endpoint ---
PAYLOAD_S3="$(python3 -c "import json; print(json.dumps({'s3':{'endpoint':'http://${S3_PL_IP}:4566','bucket':'${BUCKET}','key':'egress.txt','region':'${REGION}'}}))")"
OUT="$(invoke "$PAYLOAD_S3")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("s3",{}).get("ok") is False, d; print("s3 blocked:", d["s3"].get("detail","")[:120])' \
	&& ok "S3 prefix-list IP blocked without gateway endpoint" || bad "S3 worked without gateway endpoint: $OUT"

# --- create S3 gateway endpoint on the private RT ---
VPCE="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_A" \
	--service-name "com.amazonaws.${REGION}.s3" \
	--route-table-ids "$RTB_A" \
	--vpc-endpoint-type Gateway \
	--query 'VpcEndpoint.VpcEndpointId' --output text)"
[[ -n "$VPCE" && "$VPCE" != "None" ]] || { echo "FAIL: CreateVpcEndpoint" >&2; exit 1; }
sleep 2

OUT="$(invoke "$PAYLOAD_S3")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("s3",{}).get("ok") is True, d; print("s3 ok")' \
	&& ok "S3 via gateway endpoint prefix list" || bad "S3 via gateway endpoint failed: $OUT"

# --- (c) peer VPC ---
PAYLOAD_PEER="$(python3 -c "import json; print(json.dumps({'peerUrl':'http://${PEER_IP}/','timeoutMs':4000}))")"
OUT="$(invoke "$PAYLOAD_PEER")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("peer",{}).get("ok") is True, d; print("peer ok")' \
	&& ok "peer VPC CIDR reachable" || bad "peer VPC unreachable: $OUT"

# --- #204 sad path: removing the pcx route must fail closed ---
aws ec2 delete-route --route-table-id "$RTB_A" --destination-cidr-block "$CIDR_B" >/dev/null
sleep 2
OUT="$(invoke "$PAYLOAD_PEER")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("peer",{}).get("ok") is False, d; print("peer blocked after DeleteRoute:", d["peer"].get("detail","")[:80])' \
	&& ok "removing peering route blocks peer VPC" || bad "peer still reachable after DeleteRoute: $OUT"
aws ec2 create-route --route-table-id "$RTB_A" --destination-cidr-block "$CIDR_B" \
	--vpc-peering-connection-id "$PCX" >/dev/null
sleep 2

# --- replay after container restart (required AC) ---
CTR="$(docker ps --format '{{.Names}}' | grep -E "lambda.*${FN}|${FN}" | head -1 || true)"
if [[ -z "$CTR" ]]; then
	bad "lambda container not found for restart replay (fn=${FN})"
else
	docker stop "$CTR" >/dev/null
	docker start "$CTR" >/dev/null
	for _ in $(seq 1 40); do
		docker exec "$CTR" true >/dev/null 2>&1 && break
		sleep 1
	done
	# LocalEmu docker-events watcher re-applies mangle (CLI start bypasses SDK hook).
	RULES=""
	for _ in $(seq 1 30); do
		RULES="$(docker run --rm --privileged --network "container:${CTR}" localemu/awsbox-rt:latest \
			iptables -t mangle -S AWSBOX-RT 2>/dev/null || true)"
		if echo "$RULES" | grep -q 'AWSBOX-RT -j DROP' && echo "$RULES" | grep -q '52.216.0.0/15'; then
			break
		fi
		sleep 0.5
	done
	if echo "$RULES" | grep -q 'AWSBOX-RT -j DROP' && echo "$RULES" | grep -q '52.216.0.0/15'; then
		ok "routes replayed after container restart"
	else
		bad "routes missing after restart: ${RULES}"
	fi
fi

# --- ECS bridge attaches to subnet VPC (#230) ---
if "$ROOT/bin/vpc-egress-bridge-check.sh" "$VPC_A" "$SUB_A" "$SG_A"; then
	ok "ECS bridge subnet VPC attach"
else
	bad "ECS bridge subnet VPC attach failed"
fi

# --- IGW restores public egress ---
IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_A" >/dev/null
aws ec2 create-route --route-table-id "$RTB_A" --destination-cidr-block 0.0.0.0/0 \
	--gateway-id "$IGW" >/dev/null
sleep 2
OUT="$(invoke "$PAYLOAD_PUBLIC")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("public",{}).get("ok") is True, d; print("public ok")' \
	&& ok "IGW route restores public egress" || bad "public still blocked with IGW: $OUT"

# --- lambda-vpc-smoke still green (mapped host.docker.internal) ---
if [[ "${AWSBOX_VPC_EGRESS_SKIP_LAMBDA_VPC:-0}" != "1" ]]; then
	if "$ROOT/bin/lambda-vpc-smoke.sh"; then
		ok "lambda-vpc-smoke.sh still passes"
	else
		bad "lambda-vpc-smoke.sh failed"
	fi
fi

if [[ "$FAILS" -gt 0 ]]; then
	echo "FAIL: ${FAILS} assertion(s) failed" >&2
	exit 1
fi
echo "OK: vpc egress / gateway endpoints (#230) — slice ${SLICE}"
