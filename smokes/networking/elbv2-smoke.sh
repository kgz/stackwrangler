#!/usr/bin/env bash
# ELBv2 data plane: internet NLB :443, internal NLB :10xxx, ALB host/path, client IP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_ELBV2_KEEP:-0}"
NLB_PORT=443
INTERNAL_PORT=10080
ALB_PORT=80
TLS_PORT=8443

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC=""
SUB_A=""
SUB_B=""
SG=""
IA=""
IB=""
IC=""
LB_EDGE=""
LB_INT=""
LB_ALB=""
LB_TLS=""
DENY_USER=""
DENY_KEY=""
TG_EDGE=""
TG_INT=""
TG_A=""
TG_B=""
TG_TLS=""
CERT=""
UD_A=""
UD_B=""
UD_C=""
PEER=""
HOSTS_ADDED=0
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")

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
	if [[ "$HOSTS_ADDED" == "1" ]]; then
		sudo sed -i "/# awsbox-elbv2-smoke-${TS}/d" /etc/hosts 2>/dev/null || true
	fi
	for arn in "$LB_EDGE" "$LB_INT" "$LB_ALB" "$LB_TLS"; do
		[[ -z "$arn" ]] && continue
		aws elbv2 delete-load-balancer --load-balancer-arn "$arn" >/dev/null 2>&1 || true
	done
	for arn in "$TG_EDGE" "$TG_INT" "$TG_A" "$TG_B" "$TG_TLS"; do
		[[ -z "$arn" ]] && continue
		aws elbv2 delete-target-group --target-group-arn "$arn" >/dev/null 2>&1 || true
	done
	[[ -n "$CERT" ]] && aws acm delete-certificate --certificate-arn "$CERT" >/dev/null 2>&1 || true
	for f in "$UD_A" "$UD_B" "$UD_C" "$PEER"; do
		[[ -n "$f" ]] && rm -f "$f"
	done
	for id in "$IA" "$IB" "$IC"; do
		[[ -z "$id" ]] && continue
		aws ec2 terminate-instances --instance-ids "$id" >/dev/null 2>&1 || true
	done
	sleep 2
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	if [[ -n "$DENY_KEY" && -n "$DENY_USER" ]]; then
		aws iam delete-access-key --user-name "$DENY_USER" --access-key-id "$DENY_KEY" >/dev/null 2>&1 || true
	fi
	[[ -n "$DENY_USER" ]] && aws iam delete-user --user-name "$DENY_USER" >/dev/null 2>&1 || true
	if docker ps -q --filter "name=awsbox-elbv2-iptables" | grep -q .; then
		docker exec awsbox-elbv2-iptables nsenter -t 1 -m -n -- iptables -t nat -F AWSBOX-ELBV2 >/dev/null 2>&1 || true
		docker exec awsbox-elbv2-iptables nsenter -t 1 -m -n -- iptables -t nat -D PREROUTING -j AWSBOX-ELBV2 >/dev/null 2>&1 || true
		docker exec awsbox-elbv2-iptables nsenter -t 1 -m -n -- iptables -t nat -D OUTPUT -j AWSBOX-ELBV2 >/dev/null 2>&1 || true
		docker exec awsbox-elbv2-iptables nsenter -t 1 -m -n -- iptables -t nat -X AWSBOX-ELBV2 >/dev/null 2>&1 || true
		docker rm -f awsbox-elbv2-iptables >/dev/null 2>&1 || true
	fi
	exit "$rc"
}
trap cleanup EXIT

echo "==> authz: user with no policy cannot CreateLoadBalancer"
DENY_USER="awsbox-elbv2-deny-${TS}"
aws iam create-user --user-name "$DENY_USER" >/dev/null
DENY_JSON="$(aws iam create-access-key --user-name "$DENY_USER" --output json)"
DENY_KEY="$(echo "$DENY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENY_SECRET="$(echo "$DENY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
DENY_OUT="$(
	AWS_ACCESS_KEY_ID="$DENY_KEY" AWS_SECRET_ACCESS_KEY="$DENY_SECRET" \
		aws elbv2 create-load-balancer --name "deny-${TS}" --subnets subnet-missing --type network 2>&1
)"
DENY_RC=$?
set -e
echo "$DENY_OUT" | grep -q 'AccessDenied' || fail "expected AccessDenied, rc=${DENY_RC} out=${DENY_OUT}"
echo "OK: CreateLoadBalancer AccessDenied"

echo "==> vpc + instances"
VPC="$(aws ec2 create-vpc --cidr-block 10.203.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.203.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.203.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "elbv2-${TS}" --description "elbv2 smoke" --vpc-id "$VPC" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 18081 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 18082 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8081 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 9443 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

write_peer() {
	local path="$1"
	cat >"$path" <<'PY'
import socket, sys
mode, port_s, name = sys.argv[1], sys.argv[2], sys.argv[3]
port = int(port_s)
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(64)
while True:
    conn, addr = srv.accept()
    try:
        if mode == "http":
            conn.settimeout(2)
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
            except socket.timeout:
                pass
            head = data.split(b"\r\n", 1)[0].decode("latin1", "replace")
            host = ""
            for line in data.split(b"\r\n"):
                if line.lower().startswith(b"host:"):
                    host = line.split(b":", 1)[1].strip().decode()
            body = f"{name} {head} host={host}\n".encode()
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
        else:
            conn.sendall(f"{name} peer={addr[0]}\n".encode())
    finally:
        conn.close()
PY
}

UD_A="$(mktemp)"
UD_B="$(mktemp)"
UD_C="$(mktemp)"
PEER="$(mktemp)"
write_peer "$PEER"
python3 - "$PEER" "$UD_A" "$UD_B" "$UD_C" <<'PY'
import pathlib, sys
peer, ud_a, ud_b, ud_c = sys.argv[1:]
body = pathlib.Path(peer).read_text()

def userdata(servers: list[tuple[str, int, str]]) -> str:
    lines = ["#!/bin/bash", "cat > /tmp/peer.py << 'PY'", body, "PY"]
    for mode, port, name in servers:
        lines.append(
            f"nohup python3 /tmp/peer.py {mode} {port} {name} >/tmp/{mode}-{port}.log 2>&1 &"
        )
        lines.append(f"echo $! > /tmp/{mode}-{port}.pid")
    lines.append("touch /tmp/servers-ready")
    return "\n".join(lines) + "\n"

pathlib.Path(ud_a).write_text(userdata([
    ("tcp", 443, "A443"),
    ("tcp", 18081, "A181"),
    ("http", 8080, "TGA"),
]))
pathlib.Path(ud_b).write_text(userdata([
    ("tcp", 443, "B443"),
    ("tcp", 18082, "B182"),
    ("http", 8081, "TGB"),
    ("tcp", 9443, "BTLS"),
]))
pathlib.Path(ud_c).write_text("#!/bin/bash\ntouch /tmp/servers-ready\n")
PY

run_inst() {
	local ud="$1"
	aws ec2 run-instances \
		--image-id ami-ubuntu-22.04 \
		--instance-type t2.micro \
		--subnet-id "$SUB_A" \
		--security-group-ids "$SG" \
		--user-data "file://${ud}" \
		--query 'Instances[0].InstanceId' --output text
}

IA="$(run_inst "$UD_A")"
IB="$(run_inst "$UD_B")"
IC="$(run_inst "$UD_C")"
echo "instances A=${IA} B=${IB} client=${IC}"

wait_ready() {
	local id="$1"
	local cid=""
	local i
	for i in $(seq 1 90); do
		cid="$(cid_for "$id")"
		if [[ -n "$cid" ]] && docker exec "$cid" test -f /tmp/servers-ready; then
			echo "$cid"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: ${id} user-data did not finish" >&2
	docker ps --filter label=localemu.service=ec2 --format '{{.ID}} {{.Names}} {{.Status}}' >&2 || true
	return 1
}

CA="$(wait_ready "$IA")"
CB="$(wait_ready "$IB")"
CC="$(wait_ready "$IC")"
echo "containers ${CA} ${CB} ${CC}"

wait_local_port() {
	local cid="$1" port="$2"
	local i
	for i in $(seq 1 30); do
		if docker exec "$cid" python3 -c "import socket; socket.create_connection(('127.0.0.1', ${port}), 2).close()" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	echo "---- log ${cid} port ${port} ----" >&2
	docker exec "$cid" sh -c "ls -l /tmp; tail -n 40 /tmp/*.log /var/log/cloud-init-output.log 2>/dev/null" >&2 || true
	fail "port ${port} not up in ${cid}"
}
wait_local_port "$CA" 443
wait_local_port "$CA" 18081
wait_local_port "$CA" 8080
wait_local_port "$CB" 443
wait_local_port "$CB" 18082
wait_local_port "$CB" 8081
wait_local_port "$CB" 9443

PIP_A="$(aws ec2 describe-instances --instance-ids "$IA" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
PIP_B="$(aws ec2 describe-instances --instance-ids "$IB" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
PIP_C="$(aws ec2 describe-instances --instance-ids "$IC" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
echo "private A=${PIP_A} B=${PIP_B} client=${PIP_C}"

mk_tg() {
	local name="$1" proto="$2" port="$3"
	aws elbv2 create-target-group \
		--name "$name" --protocol "$proto" --port "$port" \
		--vpc-id "$VPC" --target-type instance \
		--health-check-protocol TCP --health-check-port traffic-port \
		--query 'TargetGroups[0].TargetGroupArn' --output text
}

TG_EDGE="$(mk_tg "e443-${TS}" TCP 443)"
TG_INT="$(mk_tg "eint-${TS}" TCP 10080)"
TG_A="$(mk_tg "ea-${TS}" HTTP 8080)"
TG_B="$(mk_tg "eb-${TS}" HTTP 8081)"
TG_TLS="$(mk_tg "etls-${TS}" TCP 9443)"

aws elbv2 register-targets --target-group-arn "$TG_EDGE" \
	--targets "Id=${IA},Port=443" "Id=${IB},Port=443"
aws elbv2 register-targets --target-group-arn "$TG_INT" \
	--targets "Id=${IA},Port=18081" "Id=${IB},Port=18082"
aws elbv2 register-targets --target-group-arn "$TG_A" --targets "Id=${IA},Port=8080"
aws elbv2 register-targets --target-group-arn "$TG_B" --targets "Id=${IB},Port=8081"
aws elbv2 register-targets --target-group-arn "$TG_TLS" --targets "Id=${IB},Port=9443"

LB_EDGE="$(aws elbv2 create-load-balancer --name "edge-${TS}" --type network \
	--scheme internet-facing --subnets "$SUB_A" "$SUB_B" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LB_INT="$(aws elbv2 create-load-balancer --name "int-${TS}" --type network \
	--scheme internal --subnets "$SUB_A" "$SUB_B" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LB_ALB="$(aws elbv2 create-load-balancer --name "alb-${TS}" --type application \
	--scheme internet-facing --subnets "$SUB_A" "$SUB_B" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LB_TLS="$(aws elbv2 create-load-balancer --name "tls-${TS}" --type network \
	--scheme internet-facing --subnets "$SUB_A" "$SUB_B" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"

LIS_EDGE="$(aws elbv2 create-listener --load-balancer-arn "$LB_EDGE" --protocol TCP --port "$NLB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG_EDGE}" --query 'Listeners[0].ListenerArn' --output text)"
LIS_INT="$(aws elbv2 create-listener --load-balancer-arn "$LB_INT" --protocol TCP --port "$INTERNAL_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG_INT}" --query 'Listeners[0].ListenerArn' --output text)"
LIS_ALB="$(aws elbv2 create-listener --load-balancer-arn "$LB_ALB" --protocol HTTP --port "$ALB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG_B}" --query 'Listeners[0].ListenerArn' --output text)"
aws elbv2 create-rule --listener-arn "$LIS_ALB" --priority 1 \
	--conditions '[{"Field":"host-header","HostHeaderConfig":{"Values":["api.example"]}},{"Field":"path-pattern","PathPatternConfig":{"Values":["/v1/*"]}}]' \
	--actions "Type=forward,TargetGroupArn=${TG_A}" >/dev/null
CERT="$(aws acm request-certificate --domain-name "elbv2-${TS}.local" --validation-method DNS \
	--query 'CertificateArn' --output text)"
LIS_TLS="$(aws elbv2 create-listener --load-balancer-arn "$LB_TLS" --protocol TLS --port "$TLS_PORT" \
	--certificates "CertificateArn=${CERT}" \
	--default-actions "Type=forward,TargetGroupArn=${TG_TLS}" --query 'Listeners[0].ListenerArn' --output text)"

dns_of() {
	aws elbv2 describe-load-balancers --load-balancer-arns "$1" --query 'LoadBalancers[0].DNSName' --output text
}
DNS_EDGE="$(dns_of "$LB_EDGE")"
DNS_INT="$(dns_of "$LB_INT")"
DNS_ALB="$(dns_of "$LB_ALB")"
echo "dns edge=${DNS_EDGE} int=${DNS_INT} alb=${DNS_ALB}"

LS="$("${COMPOSE[@]}" ps -q localstack)"
[[ -n "$LS" ]] || fail "localstack container not running"
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
[[ -n "$EDGE" ]] || fail "no edge IP on localemu"
echo "edge_ip=${EDGE}"

wait_healthy() {
	local arn="$1" want="$2"
	local i n
	for i in $(seq 1 40); do
		n="$(aws elbv2 describe-target-health --target-group-arn "$arn" \
			--query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
		echo "health ${arn##*/} healthy=${n}"
		[[ "$n" == "$want" ]] && return 0
		sleep 2
	done
	aws elbv2 describe-target-health --target-group-arn "$arn" >&2 || true
	fail "target group ${arn} did not reach ${want} healthy"
}
wait_healthy "$TG_EDGE" 2
wait_healthy "$TG_INT" 2
wait_healthy "$TG_A" 1
wait_healthy "$TG_B" 1
wait_healthy "$TG_TLS" 1

echo "==> DNS from a VPC workload"
for i in $(seq 1 20); do
	if docker exec "$CC" getent hosts "$DNS_EDGE" | grep -q . \
		&& docker exec "$CC" getent hosts "$DNS_INT" | grep -q .; then
		break
	fi
	sleep 1
	[[ "$i" == "20" ]] && fail "LB DNS did not resolve in the VPC workload"
done
docker exec "$CC" getent hosts "$DNS_EDGE" "$DNS_INT"
echo "OK: workload DNS"

HOSTS_FILE="$ROOT/.awsbox/elbv2.hosts"
[[ -f "$HOSTS_FILE" ]] || fail "missing ${HOSTS_FILE}"
grep -q "$DNS_EDGE" "$HOSTS_FILE" || fail "edge DNS missing from elbv2.hosts"
grep -q "$DNS_INT" "$HOSTS_FILE" || fail "internal DNS missing from elbv2.hosts"
if sudo -n true 2>/dev/null; then
	while read -r ip name _; do
		[[ "$ip" == \#* || -z "${name:-}" ]] && continue
		echo "${ip} ${name} # awsbox-elbv2-smoke-${TS}" | sudo tee -a /etc/hosts >/dev/null
	done <"$HOSTS_FILE"
	HOSTS_ADDED=1
	getent hosts "$DNS_EDGE" | grep -q . || fail "host did not resolve ${DNS_EDGE}"
	getent hosts "$DNS_INT" | grep -q . || fail "host did not resolve ${DNS_INT}"
	echo "OK: host DNS"
else
	fail "sudo required to prove host DNS via /etc/hosts"
fi

tcp_once() {
	local ip="$1" port="$2"
	python3 - "$ip" "$port" <<'PY'
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)
s.settimeout(5)
data = s.recv(256)
s.close()
sys.stdout.write(data.decode())
PY
}

echo "==> internet-facing NLB :${NLB_PORT}"
EDGE_NAMES=""
for _ in $(seq 1 12); do
	line="$(tcp_once "$EDGE" "$NLB_PORT")"
	echo "  ${line}"
	EDGE_NAMES="${EDGE_NAMES} ${line%% *}"
done
echo "$EDGE_NAMES" | grep -q A443 || fail "NLB :443 missed A443 (${EDGE_NAMES})"
echo "$EDGE_NAMES" | grep -q B443 || fail "NLB :443 missed B443 (${EDGE_NAMES})"
echo "OK: both instance targets on :443"

echo "==> internal NLB not on the edge address"
set +e
python3 - "$EDGE" "$INTERNAL_PORT" <<'PY'
import socket, sys
socket.create_connection((sys.argv[1], int(sys.argv[2])), 2).close()
PY
INT_EDGE_RC=$?
set -e
[[ "$INT_EDGE_RC" -ne 0 ]] || fail "internal NLB accepted a connection on the edge IP"
echo "OK: internal listener closed on edge IP"

echo "==> internal NLB :${INTERNAL_PORT} from VPC client"
INT_OUT="$(docker exec -i "$CC" python3 - "$DNS_INT" "$INTERNAL_PORT" <<'PY'
import socket, sys
names = set()
for _ in range(12):
    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)
    s.settimeout(5)
    line = s.recv(256).decode().split()[0]
    s.close()
    names.add(line)
    print(line)
print("NAMES " + " ".join(sorted(names)))
PY
)"
echo "$INT_OUT"
echo "$INT_OUT" | grep -q A181 || fail "internal NLB missed A181"
echo "$INT_OUT" | grep -q B182 || fail "internal NLB missed B182"
echo "OK: internal NLB both ports"

echo "==> client source IP through NLB"
CIP_OUT="$(docker exec -i "$CC" python3 - "$DNS_EDGE" "$NLB_PORT" <<'PY'
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)
local = s.getsockname()[0]
s.settimeout(5)
body = s.recv(256).decode().strip()
s.close()
print(f"local={local} body={body}")
PY
)"
echo "  ${CIP_OUT}"
LOCAL_IP="$(echo "$CIP_OUT" | sed -n 's/.*local=\([^ ]*\).*/\1/p')"
PEER_IP="$(echo "$CIP_OUT" | sed -n 's/.*peer=\([^ ]*\).*/\1/p')"
[[ -n "$LOCAL_IP" && -n "$PEER_IP" ]] || fail "could not parse client IP line: ${CIP_OUT}"
[[ "$PEER_IP" == "$LOCAL_IP" ]] || fail "target saw ${PEER_IP}, client source was ${LOCAL_IP}"
echo "OK: target saw client ${PEER_IP}"

echo "==> ALB host + path + default"
http_once() {
	local ip="$1" host="$2" path="$3"
	python3 - "$ip" "$ALB_PORT" "$host" "$path" <<'PY'
import socket, sys
ip, port, host, path = sys.argv[1:]
s = socket.create_connection((ip, int(port)), 5)
s.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
data = b""
s.settimeout(5)
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
s.close()
print(data.decode("latin1", "replace").split("\r\n\r\n", 1)[-1].strip())
PY
}
HIT_A="$(http_once "$EDGE" api.example /v1/hello)"
HIT_PATH="$(http_once "$EDGE" api.example /other)"
HIT_HOST="$(http_once "$EDGE" nope.example /v1/hello)"
echo "  api/v1=${HIT_A}"
echo "  api/other=${HIT_PATH}"
echo "  nope/v1=${HIT_HOST}"
echo "$HIT_A" | grep -q '^TGA' || fail "host+path should hit TGA (${HIT_A})"
echo "$HIT_A" | grep -q 'host=api.example' || fail "ALB should forward the client Host (${HIT_A})"
echo "$HIT_PATH" | grep -q '^TGB' || fail "path miss should hit default TGB (${HIT_PATH})"
echo "$HIT_HOST" | grep -q '^TGB' || fail "host miss should hit default TGB (${HIT_HOST})"
echo "$HIT_HOST" | grep -q 'host=nope.example' || fail "ALB should forward the client Host (${HIT_HOST})"
echo "OK: ALB rules"

echo "==> NLB TLS :${TLS_PORT}"
TLS_BODY="$(python3 - "$EDGE" "$TLS_PORT" <<'PY'
import socket, ssl, sys
ctx = ssl._create_unverified_context()
raw = socket.create_connection((sys.argv[1], int(sys.argv[2])), 5)
ss = ctx.wrap_socket(raw, server_hostname="elbv2.local")
ss.settimeout(5)
ss.sendall(b"hi")
data = ss.recv(256)
ss.close()
sys.stdout.write(data.decode())
PY
)"
echo "  ${TLS_BODY}"
echo "$TLS_BODY" | grep -q BTLS || fail "TLS listener did not reach BTLS (${TLS_BODY})"
echo "OK: TLS forward"

echo "==> unhealthy target drops out"
docker exec "$CA" sh -c 'kill "$(cat /tmp/tcp-443.pid)"' || fail "could not stop A443"
UNHEALTHY=""
for i in $(seq 1 20); do
	UNHEALTHY="$(aws elbv2 describe-target-health --target-group-arn "$TG_EDGE" \
		--targets "Id=${IA},Port=443" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
	echo "  A443=${UNHEALTHY}"
	[[ "$UNHEALTHY" == "unhealthy" ]] && break
	sleep 1
done
[[ "$UNHEALTHY" == "unhealthy" ]] || fail "A443 stayed ${UNHEALTHY}"
AFTER=""
for _ in $(seq 1 8); do
	line="$(tcp_once "$EDGE" "$NLB_PORT")"
	echo "  ${line}"
	AFTER="${AFTER} ${line%% *}"
done
echo "$AFTER" | grep -q A443 && fail "unhealthy A443 still received traffic (${AFTER})"
echo "$AFTER" | grep -q B443 || fail "healthy B443 got no traffic (${AFTER})"
echo "OK: unhealthy target dropped"

echo "OK: elbv2 smoke"
rm -f "$UD_A" "$UD_B" "$UD_C" "$PEER"
