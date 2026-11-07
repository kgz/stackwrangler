#!/usr/bin/env bash
# Fidelity: two awsvpc ECS tasks on one Docker host — direct ENI vs internal NLB VIP.
#
# When host chain AWSBOX-ELBV2 DNATs the VIP to the target (client-IP retention),
# peer→VIP hairpins on the bridge and fails — same class of failure as real AWS
# NLB same-host + preserve_client_ip. Direct ENI still works. See docs/ecs-hairpin.md.
# Do not create real AWS resources here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${AWSBOX_HAIRPIN_KEEP:-0}"
WORK="$ROOT/.awsbox/ecs-hairpin-${TS}"
CLUSTER="hairpin-${TS}"
FAMILY_SRV="hairpin-srv-${TS}"
FAMILY_CLI="hairpin-cli-${TS}"
NLB_PORT=18080

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB="" SG="" LB="" TG="" LISTENER="" TASK_SRV="" TASK_CLI="" TD_SRV="" TD_CLI=""

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$LISTENER" ]] && aws elbv2 delete-listener --listener-arn "$LISTENER" >/dev/null 2>&1 || true
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$TASK_SRV" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_SRV" >/dev/null 2>&1 || true
	[[ -n "$TASK_CLI" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_CLI" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$TD_SRV" ]] && aws ecs deregister-task-definition --task-definition "$TD_SRV" >/dev/null 2>&1 || true
	[[ -n "$TD_CLI" ]] && aws ecs deregister-task-definition --task-definition "$TD_CLI" >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	if [[ -n "$VPC" ]]; then
		net="localemu-vpc-${VPC}"
		for cid in $(docker network inspect "$net" -f '{{range $k,$v := .Containers}}{{$k}} {{end}}' 2>/dev/null); do
			docker network disconnect -f "$net" "$cid" >/dev/null 2>&1 || true
		done
		docker network rm "$net" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$WORK"

echo "==> VPC + SG"
VPC_CIDR="${AWSBOX_SMOKE_VPC_CIDR:-$(
python3 - <<'PY'
import json, subprocess
used = set()
try:
    out = subprocess.check_output(
        ["docker", "network", "ls", "--format", "{{.Name}}"], text=True
    )
except Exception:
    out = ""
for name in out.splitlines():
    if not name.startswith("localemu-vpc-"):
        continue
    try:
        raw = subprocess.check_output(
            ["docker", "network", "inspect", name], text=True
        )
        cfg = json.loads(raw)[0].get("IPAM", {}).get("Config") or []
        for c in cfg:
            cidr = c.get("Subnet") or ""
            if cidr:
                used.add(cidr)
    except Exception:
        pass
for i in range(180, 250):
    cand = f"10.{i}.0.0/16"
    if cand not in used:
        print(cand)
        break
else:
    print("10.249.0.0/16")
PY
)}"
SUB_CIDR="${AWSBOX_SMOKE_SUBNET_CIDR:-$(python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); print(list(n.subnets(new_prefix=24))[1] if n.prefixlen<=24 else str(n))' "$VPC_CIDR")}"
echo "using VPC_CIDR=${VPC_CIDR} SUB_CIDR=${SUB_CIDR}"
VPC="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --query Vpc.VpcId --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$SUB_CIDR" --query Subnet.SubnetId --output text)"
SG="$(aws ec2 create-security-group --group-name "hairpin-${TS}" --description "ecs hairpin" --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$NLB_PORT" --cidr 0.0.0.0/0 >/dev/null

# Server: echo peer (source) IP so we can see NAT / proxy retention through the VIP.
NGINX_CONF='server { listen 8080; location / { return 200 "peer=$remote_addr\n"; add_header Content-Type text/plain; } }'
python3 - "$NGINX_CONF" >"$WORK/server.json" <<'PY'
import json, sys
cmd = "printf '%s' \"$NGINX_CONF\" > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'"
print(json.dumps([{
    "name": "web",
    "image": "nginx:alpine",
    "essential": True,
    "memory": 128,
    "command": ["sh", "-c", cmd],
    "environment": [{"name": "NGINX_CONF", "value": sys.argv[1]}],
    "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
}]))
PY
python3 >"$WORK/client.json" <<'PY'
import json
print(json.dumps([{
    "name": "cli",
    "image": "curlimages/curl:8.5.0",
    "essential": True,
    "memory": 128,
    "command": ["sh", "-c", "sleep 3600"],
    "portMappings": [],
}]))
PY

NET="awsvpcConfiguration={subnets=[${SUB}],securityGroups=[${SG}],assignPublicIp=DISABLED}"

echo "==> ECS cluster + two awsvpc tasks (same Docker host)"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
TD_SRV="$(aws ecs register-task-definition --family "$FAMILY_SRV" --requires-compatibilities FARGATE \
	--network-mode awsvpc --cpu 256 --memory 512 --container-definitions "file://${WORK}/server.json" \
	--query taskDefinition.taskDefinitionArn --output text)"
TD_CLI="$(aws ecs register-task-definition --family "$FAMILY_CLI" --requires-compatibilities FARGATE \
	--network-mode awsvpc --cpu 256 --memory 512 --container-definitions "file://${WORK}/client.json" \
	--query taskDefinition.taskDefinitionArn --output text)"
TASK_SRV="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_SRV" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
TASK_CLI="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_CLI" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"

task_info() {
	local task="$1"
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --output json | python3 -c '
import json, sys, subprocess
t = json.load(sys.stdin)["tasks"][0]
status = t.get("lastStatus") or ""
arn = t.get("taskArn") or ""
ip = ""
for a in t.get("attachments") or []:
    for d in a.get("details") or []:
        if d.get("name") == "privateIPv4Address" and d.get("value"):
            ip = d["value"]
ctr = ""
if arn:
    try:
        names = subprocess.check_output(
            ["docker", "ps", "--filter", f"label=localemu.task-arn={arn}",
             "--format", "{{.Names}}"],
            text=True,
        ).strip().splitlines()
        if names:
            ctr = names[0]
            dip = subprocess.check_output(
                ["docker", "inspect", "-f",
                 "{{range $k,$v := .NetworkSettings.Networks}}"
                 "{{printf \"%s=%s\\n\" $k $v.IPAddress}}{{end}}",
                 ctr],
                text=True,
            )
            for line in dip.splitlines():
                if line.startswith("localemu-vpc-") and "=" in line:
                    cand = line.split("=", 1)[1].strip()
                    if cand:
                        ip = cand
                        break
    except Exception:
        pass
print(status)
print(ip)
print(ctr)
'
}

wait_task() {
	local label="$1" task="$2"
	local status="" ip="" ctr=""
	local i
	for i in $(seq 1 90); do
		mapfile -t info < <(task_info "$task")
		status="${info[0]:-}"
		ip="${info[1]:-}"
		ctr="${info[2]:-}"
		if [[ "$status" == "RUNNING" && -n "$ip" && -n "$ctr" ]]; then
			echo "$label status=${status} ip=${ip} ctr=${ctr}" >&2
			printf '%s\n' "$status" "$ip" "$ctr"
			return 0
		fi
		if [[ "$status" == "STOPPED" && "$i" -gt 8 ]]; then
			aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" >&2 || true
			fail "${label} stopped before RUNNING"
		fi
		sleep 2
	done
	fail "${label} not RUNNING (last=${status})"
}

mapfile -t SRV < <(wait_task server "$TASK_SRV")
SRV_IP="${SRV[1]}"
SRV_CTR="${SRV[2]}"
mapfile -t CLI < <(wait_task client "$TASK_CLI")
CLI_IP="${CLI[1]}"
CLI_CTR="${CLI[2]}"

[[ -n "$SRV_IP" && -n "$CLI_IP" ]] || fail "missing task IPs"
[[ "$SRV_IP" != "$CLI_IP" ]] || fail "server and client share the same IP"

echo "==> baseline: client → server direct IP (no VIP)"
DIRECT=""
for _ in $(seq 1 30); do
	DIRECT="$(docker exec "$CLI_CTR" curl -sf -m 3 "http://${SRV_IP}:8080/" 2>/dev/null || true)"
	[[ "$DIRECT" == peer=* ]] && break
	sleep 1
done
[[ "$DIRECT" == peer=* ]] || fail "direct path failed (got '${DIRECT}')"
DIRECT_PEER="${DIRECT#peer=}"
echo "ok   direct: ${DIRECT} (client ENI ${CLI_IP})"
# Direct L3 on the VPC bridge should show the client ENI (or an SNAT of it).
if [[ "$DIRECT_PEER" != "$CLI_IP" ]]; then
	echo "note: direct peer=${DIRECT_PEER} != client ENI ${CLI_IP} (bridge/SNAT may rewrite)"
fi

echo "==> internal NLB + ip target group (AWS service VIP shape)"
LB="$(aws elbv2 create-load-balancer --name "hp${TS}" --type network --scheme internal \
	--subnets "$SUB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
NLB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" \
	--query 'LoadBalancers[0].DNSName' --output text)"
TG="$(aws elbv2 create-target-group --name "hptg${TS}" --protocol TCP --port 8080 \
	--vpc-id "$VPC" --target-type ip \
	--health-check-protocol TCP --health-check-port traffic-port \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${SRV_IP},Port=8080"
LISTENER="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol TCP --port "$NLB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"

for _ in $(seq 1 40); do
	th="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
		--query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || true)"
	[[ "$th" == "healthy" ]] && break
	sleep 1
done
th="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
	--query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || true)"
[[ "$th" == "healthy" ]] || fail "target not healthy (state=${th})"
echo "ok   target healthy; dns=${NLB_DNS}"

LS="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "localstack container not running"
LB_VPC_IP="$(docker inspect "$LS" -f "{{(index .NetworkSettings.Networks \"localemu-vpc-${VPC}\").IPAddress}}" 2>/dev/null || true)"
[[ -n "$LB_VPC_IP" && "$LB_VPC_IP" != "<no value>" ]] || fail "no LocalEmu address on localemu-vpc-${VPC}"
echo "LB_VPC_IP=${LB_VPC_IP}"

# DNS should resolve inside the client (LocalEmu writes /etc/hosts for VPC workloads).
RESOLVED="$(docker exec "$CLI_CTR" getent hosts "$NLB_DNS" 2>/dev/null | awk '{print $1; exit}' || true)"
if [[ -z "$RESOLVED" ]]; then
	echo "note: NLB DNS not in client hosts yet; probing VPC IP ${LB_VPC_IP}"
	RESOLVED="$LB_VPC_IP"
else
	echo "ok   client resolves ${NLB_DNS} → ${RESOLVED}"
fi

VIP_URL="http://${RESOLVED}:${NLB_PORT}/"
echo "==> peer task → VIP (same-host hairpin)"
VIA=""
# Few short attempts: DNAT hairpin times out; userspace proxy answers immediately.
for _ in $(seq 1 5); do
	VIA="$(docker exec "$CLI_CTR" curl -sf -m 2 "$VIP_URL" 2>/dev/null || true)"
	[[ "$VIA" == peer=* ]] && break
	sleep 1
done

MODE=""
if [[ "$VIA" == peer=* ]]; then
	# Host DNAT absent → userspace proxy. Target often sees proxy IP (#236).
	echo "ok   peer→VIP via userspace proxy: ${VIA}"
	MODE=proxy-success
	VIA_PEER="${VIA#peer=}"
	if [[ "$VIA_PEER" != "$CLI_IP" ]]; then
		echo "note: retention peer=${VIA_PEER} != client ${CLI_IP} (proxy path; see #236)"
	fi
else
	# Host AWSBOX-ELBV2 DNAT + same-bridge hairpin — AWS-like failure.
	echo "ok   peer→VIP failed (AWS-like DNAT hairpin; got='${VIA}')"
	MODE=dnat-hairpin-fail
	SELF="$(docker exec "$LS" curl -sf -m 3 "http://${LB_VPC_IP}:${NLB_PORT}/" 2>/dev/null || true)"
	[[ "$SELF" == peer=* ]] || fail "LocalEmu→self VIP should still work when peer hairpin fails (got='${SELF}')"
	echo "ok   LocalEmu→self VIP works (local delivery): ${SELF}"
fi

cat <<EOF
OK: ecs same-host VIP hairpin fidelity
  server=${SRV_IP} client=${CLI_IP}
  direct=${DIRECT} mode=${MODE} vip=${VIP_URL}
  docs=docs/ecs-hairpin.md
EOF
