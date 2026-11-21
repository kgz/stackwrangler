#!/usr/bin/env bash
# Dual-target: ALB security-group membership (#768).
# Target SG admits only from the ALB SG → healthy + listener forward.
# Local also asserts peer outside A is denied; real asserts LB ENIs carry SG_A.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
PORT=8080
ALB_PORT=80
ACCT="$PARITY_ACCOUNT"
REGION="$PARITY_REGION"
CLUSTER="sw-parity-elbsg-${TS}"
FAMILY="sw-parity-elbsg-${TS}"

VPC="" SUB_A="" SUB_B="" IGW="" RTB_A="" RTB_B=""
SG_A="" SG_T="" SG_B=""
LB="" TG="" LIS=""
TASK="" TD="" EXEC_ROLE_ARN=""
AZ_A="" AZ_B=""

# LIFO: VPC first registered (deleted last).
on_cleanup '[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC"'
on_cleanup '[[ -n "$IGW" ]] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"'
on_cleanup '[[ -n "$RTB_A" && -n "$IGW" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"'
on_cleanup '[[ -n "$RTB_A" ]] && aws ec2 delete-route-table --route-table-id "$RTB_A"'
on_cleanup '[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A"'
on_cleanup '[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B"'
on_cleanup '[[ -n "$SG_T" ]] && aws ec2 delete-security-group --group-id "$SG_T"'
on_cleanup '[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A"'
on_cleanup '[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B"'
on_cleanup '[[ -n "$TD" ]] && aws ecs deregister-task-definition --task-definition "$TD"'
on_cleanup "aws ecs delete-cluster --cluster '$CLUSTER'"
on_cleanup '[[ -n "$TASK" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK"; sleep 15'
on_cleanup '[[ -n "$TG" ]] && sleep 5; aws elbv2 delete-target-group --target-group-arn "$TG"'
on_cleanup '[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB"; sleep 20'

if [[ "$PARITY_TARGET" == "real" ]]; then
	EXEC_ROLE_ARN="arn:aws:iam::${ACCT}:role/ecsTaskExecutionRole"
	aws iam get-role --role-name ecsTaskExecutionRole >/dev/null \
		|| parity_die "real needs iam role ecsTaskExecutionRole"
	mapfile -t AZS < <(aws ec2 describe-availability-zones --query 'AvailabilityZones[?State==`available`].ZoneName' --output text | tr '\t' '\n' | head -2)
	AZ_A="${AZS[0]:-}"
	AZ_B="${AZS[1]:-}"
	[[ -n "$AZ_A" && -n "$AZ_B" ]] || parity_die "need 2 AZs"
else
	AZ_A="${REGION}a"
	AZ_B="${REGION}b"
fi

echo "==> VPC / subnets / SGs"
VPC="$(aws ec2 create-vpc --cidr-block 10.219.0.0/16 --query Vpc.VpcId --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support >/dev/null
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames >/dev/null
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.219.1.0/24 --availability-zone "$AZ_A" --query Subnet.SubnetId --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.219.2.0/24 --availability-zone "$AZ_B" --query Subnet.SubnetId --output text)"
aws ec2 modify-subnet-attribute --subnet-id "$SUB_A" --map-public-ip-on-launch >/dev/null
aws ec2 modify-subnet-attribute --subnet-id "$SUB_B" --map-public-ip-on-launch >/dev/null

if [[ "$PARITY_TARGET" == "real" ]]; then
	IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
	aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" >/dev/null
	RTB_A="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
	aws ec2 create-route --route-table-id "$RTB_A" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
	aws ec2 associate-route-table --route-table-id "$RTB_A" --subnet-id "$SUB_A" >/dev/null
	aws ec2 associate-route-table --route-table-id "$RTB_A" --subnet-id "$SUB_B" >/dev/null
fi

SG_A="$(aws ec2 create-security-group --group-name "sw-parity-elbsg-a-${TS}" --description alb --vpc-id "$VPC" --query GroupId --output text)"
SG_T="$(aws ec2 create-security-group --group-name "sw-parity-elbsg-t-${TS}" --description target --vpc-id "$VPC" --query GroupId --output text)"
SG_B="$(aws ec2 create-security-group --group-name "sw-parity-elbsg-b-${TS}" --description peer --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_A" --protocol tcp --port "$ALB_PORT" --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_A" >/dev/null

CDEF="$(PORT="$PORT" TS="$TS" python3 - <<'PY'
import json, os
port = int(os.environ["PORT"])
ts = os.environ["TS"]
print(json.dumps([{
    "name": "web",
    "image": "hashicorp/http-echo:1.0",
    "essential": True,
    "memory": 128,
    "command": ["-listen", f":{port}", "-text", f"elbv2-sg-ok-{ts}"],
    "portMappings": [{"containerPort": port, "hostPort": port, "protocol": "tcp"}],
}]))
PY
)"

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
REG_ARGS=(
	ecs register-task-definition --family "$FAMILY"
	--requires-compatibilities FARGATE --network-mode awsvpc
	--cpu 256 --memory 512 --container-definitions "$CDEF"
	--query taskDefinition.taskDefinitionArn --output text
)
if [[ -n "$EXEC_ROLE_ARN" ]]; then
	REG_ARGS+=(--execution-role-arn "$EXEC_ROLE_ARN")
fi
TD="$(aws "${REG_ARGS[@]}")"

NET="awsvpcConfiguration={subnets=[${SUB_A}],securityGroups=[${SG_T}],assignPublicIp=ENABLED}"
TASK="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
[[ -n "$TASK" && "$TASK" != "None" ]] || parity_die "RunTask empty"

TIP=""
for i in $(seq 1 120); do
	TIP="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --output json | python3 -c '
import json,sys
t=json.load(sys.stdin)["tasks"][0]
if t.get("lastStatus")!="RUNNING":
    print(""); raise SystemExit
ip=""
for a in t.get("attachments") or []:
  for d in a.get("details") or []:
    if d.get("name")=="privateIPv4Address": ip=d.get("value") or ""
print(ip)
')"
	[[ -n "$TIP" ]] && break
	st="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --query 'tasks[0].lastStatus' --output text)"
	[[ "$st" == "STOPPED" && "$i" -gt 15 ]] && parity_die "task STOPPED early"
	sleep 2
done
[[ -n "$TIP" ]] || parity_die "task never RUNNING with private IP"
echo "target task ip=${TIP}"

TG="$(aws elbv2 create-target-group \
	--name "psgt${TS: -8}" --protocol HTTP --port "$PORT" \
	--vpc-id "$VPC" --target-type ip \
	--health-check-protocol HTTP --health-check-path / \
	--health-check-interval-seconds 10 --healthy-threshold-count 2 \
	--matcher HttpCode=200 \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer \
	--name "psga${TS: -8}" --type application --scheme internet-facing \
	--subnets "$SUB_A" "$SUB_B" --security-groups "$SG_A" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${TIP},Port=${PORT}" >/dev/null
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol HTTP --port "$ALB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"
DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --query 'LoadBalancers[0].DNSName' --output text)"

wait_healthy() {
	local i state
	for i in $(seq 1 60); do
		state="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
			--query "TargetHealthDescriptions[0].TargetHealth.State" --output text 2>/dev/null || echo unknown)"
		echo "health try=${i} state=${state}"
		[[ "$state" == "healthy" ]] && return 0
		sleep 3
	done
	aws elbv2 describe-target-health --target-group-arn "$TG" >&2 || true
	parity_die "target not healthy (ALB SG membership)"
}
wait_healthy
parity_pass "target healthy via ALB SG reference"

if [[ "$PARITY_TARGET" == "local" ]]; then
	LS="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null || true)"
	[[ -n "$LS" ]] || parity_die "LocalEmu not up"
	EDGE="$(docker inspect "$LS" | python3 -c '
import json,sys
nets=json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]
for name,cfg in nets.items():
  if name.startswith("localemu-"): continue
  ip=cfg.get("IPAddress") or ""
  if ip: print(ip); break
')"
	[[ -n "$EDGE" ]] || parity_die "no edge IP"
	BODY="$(python3 - "$EDGE" "$ALB_PORT" "$DNS" <<'PY'
import http.client, sys
edge, port, host = sys.argv[1], int(sys.argv[2]), sys.argv[3]
conn = http.client.HTTPConnection(edge, port, timeout=8)
conn.request("GET", "/", headers={"Host": host})
resp = conn.getresponse()
print(resp.status)
print(resp.read().decode())
conn.close()
PY
)"
	STATUS="$(echo "$BODY" | head -1)"
	PAYLOAD="$(echo "$BODY" | tail -n +2)"
	[[ "$STATUS" == "200" ]] || parity_die "ALB status=${STATUS} body=${PAYLOAD}"
	[[ "$PAYLOAD" == *"elbv2-sg-ok-${TS}"* ]] || parity_die "unexpected body ${PAYLOAD}"
	parity_pass "local: ALB Host-forward reached target"
else
	BODY=""
	for _ in $(seq 1 40); do
		BODY="$(curl -sf -m 8 "http://${DNS}/" 2>/dev/null || true)"
		[[ "$BODY" == *"elbv2-sg-ok-${TS}"* ]] && break
		sleep 3
	done
	[[ "$BODY" == *"elbv2-sg-ok-${TS}"* ]] || parity_die "real ALB curl failed (${BODY})"
	parity_pass "real: ALB DNS forward reached target"

	# LB ENIs must carry SG_A (AWS behaviour the local AddressIndex mirrors).
	ENI_SGS="$(aws ec2 describe-network-interfaces \
		--filters "Name=description,Values=*${LB##*/}*" "Name=vpc-id,Values=${VPC}" \
		--query 'NetworkInterfaces[].Groups[].GroupId' --output text 2>/dev/null || true)"
	if [[ -z "$ENI_SGS" ]]; then
		# Fallback: any amazon-elb ENI in this VPC
		ENI_SGS="$(aws ec2 describe-network-interfaces \
			--filters "Name=vpc-id,Values=${VPC}" "Name=interface-type,Values=network_load_balancer,Name=requester-id,Values=amazon-elb" \
			--query 'NetworkInterfaces[].Groups[].GroupId' --output text 2>/dev/null || true)"
	fi
	if [[ -z "$ENI_SGS" ]]; then
		ENI_SGS="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC}" \
			--query "NetworkInterfaces[?contains(Description, 'ELB') || contains(Description, 'elbv2')].Groups[].GroupId" --output text)"
	fi
	echo "$ENI_SGS" | tr '\t' '\n' | grep -qx "$SG_A" \
		|| parity_die "LB ENIs missing SG_A=${SG_A} (got ${ENI_SGS})"
	parity_pass "real: LB ENIs members of SG_A"
fi

parity_finish
