#!/usr/bin/env bash
# Interface VPCE private DNS (#258).
# In-VPC workload resolves service hostnames to the endpoint and reaches awsbox;
# a workload in another VPC does not get that private resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

HOST_PORT="${AWSBOX_VPCE_HOST_PORT:-24568}"
CREDS_PORT="${AWSBOX_VPCE_ECS_CREDS_PORT:-24571}"
EP="${AWSBOX_VPCE_ENDPOINT:-http://127.0.0.1:${HOST_PORT}}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_VPCE_KEEP:-0}"
CLUSTER="vpce-dns-${TS}"
FAMILY="vpce-dns-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_LOCALEMU_HOST_PORT="$HOST_PORT"
export AWSBOX_ECS_CREDS_PORT="$CREDS_PORT"
export AWSBOX_SECRET_KEY="$SECRET"
export AWSBOX_ACCESS_KEY="$KEY"

VPC_A="" VPC_B="" SUB_A="" SUB_B="" SG_A="" SG_B=""
TASK_A="" TASK_B=""
VPCE_IDS=()
LS=""

SERVICES=(
	"com.amazonaws.${REGION}.sts:sts.${REGION}.amazonaws.com"
	"com.amazonaws.${REGION}.logs:logs.${REGION}.amazonaws.com"
	"com.amazonaws.${REGION}.ssm:ssm.${REGION}.amazonaws.com"
	"com.amazonaws.${REGION}.ecs:ecs.${REGION}.amazonaws.com"
	"com.amazonaws.${REGION}.ecr.api:api.ecr.${REGION}.amazonaws.com"
	"com.amazonaws.${REGION}.ecr.dkr:dkr.ecr.${REGION}.amazonaws.com"
)

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	local rc=$?
	set +e
	if [[ "$KEEP" == "1" ]]; then
		echo "KEEP=1; leaving resources (exit $rc)"
		exit "$rc"
	fi
	[[ -n "$TASK_A" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_A" >/dev/null 2>&1
	[[ -n "$TASK_B" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_B" >/dev/null 2>&1
	if [[ ${#VPCE_IDS[@]} -gt 0 ]]; then
		aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${VPCE_IDS[@]}" >/dev/null 2>&1
	fi
	sleep 2
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1
	[[ -n "$VPC_A" ]] && aws ec2 delete-vpc --vpc-id "$VPC_A" >/dev/null 2>&1
	[[ -n "$VPC_B" ]] && aws ec2 delete-vpc --vpc-id "$VPC_B" >/dev/null 2>&1
	exit "$rc"
}
trap cleanup EXIT

echo "endpoint ${EP}"
docker compose -f "$ROOT/docker-compose.yml" up -d --force-recreate --no-deps localstack
for _ in $(seq 1 90); do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
	[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && break
	sleep 2
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
[[ "$code" =~ ^[12345][0-9][0-9]$ ]] || fail "LocalEmu not ready at ${EP} (${code})"

LS="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack)"
[[ -n "$LS" ]] || fail "localstack container missing"
for _ in $(seq 1 40); do
	docker exec "$LS" grep -q "VPCE private DNS resolver starting" /tmp/vpce-resolver.log 2>/dev/null && break
	sleep 1
done
docker exec "$LS" grep -q "VPCE private DNS resolver starting" /tmp/vpce-resolver.log \
	|| fail "resolver did not start ($(docker exec "$LS" cat /tmp/vpce-resolver.log 2>/dev/null | tail -20))"

VPC_A="$(aws ec2 create-vpc --cidr-block 10.58.0.0/16 --query 'Vpc.VpcId' --output text)"
VPC_B="$(aws ec2 create-vpc --cidr-block 10.59.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.58.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block 10.59.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SG_A="$(aws ec2 create-security-group --group-name "vpce-a-${TS}" --description vpce-dns --vpc-id "$VPC_A" --query 'GroupId' --output text)"
SG_B="$(aws ec2 create-security-group --group-name "vpce-b-${TS}" --description vpce-dns --vpc-id "$VPC_B" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_A" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_B" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

declare -A HOST_TO_IP=()
for pair in "${SERVICES[@]}"; do
	svc="${pair%%:*}"
	host="${pair#*:}"
	ep_json="$(aws ec2 create-vpc-endpoint \
		--vpc-id "$VPC_A" \
		--vpc-endpoint-type Interface \
		--service-name "$svc" \
		--subnet-ids "$SUB_A" \
		--security-group-ids "$SG_A" \
		--private-dns-enabled \
		--output json)"
	epid="$(printf '%s' "$ep_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["VpcEndpoint"]["VpcEndpointId"])')"
	VPCE_IDS+=("$epid")
	printf '%s' "$ep_json" | python3 -c 'import json,sys
ep=json.load(sys.stdin)["VpcEndpoint"]
assert ep.get("PrivateDnsEnabled") is True, ep
assert (ep.get("State") or "").lower()=="available", ep.get("State")
' || fail "create ${svc}: PrivateDnsEnabled/available missing"
	proxy_ip="$(printf '%s' "$ep_json" | python3 -c 'import json,sys,ipaddress
ep=json.load(sys.stdin)["VpcEndpoint"]
for e in ep.get("DnsEntries") or []:
    n=(e.get("DnsName") or "").split(":")[0]
    try:
        ipaddress.ip_address(n)
        print(n)
        break
    except ValueError:
        pass
')"
	if [[ -z "$proxy_ip" ]]; then
		proxy_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"localemu-vpc-${VPC_A}\").IPAddress}}" "localemu-vpce-${epid}" 2>/dev/null || true)"
	fi
	[[ -n "$proxy_ip" ]] || fail "no proxy IP for ${svc}"
	HOST_TO_IP["$host"]="$proxy_ip"
	echo "ok endpoint ${epid} ${host} -> ${proxy_ip}"
done

# Sleeping alpine so we can getent/curl inside the task containers.
python3 - "$FAMILY" >"/tmp/vpce-td-${FAMILY}.json" <<'PY'
import json, sys
family = sys.argv[1]
print(json.dumps({
    "family": family,
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [{
        "name": "main",
        "image": "alpine:3.20",
        "essential": True,
        "memory": 128,
        "command": ["sh", "-c", "sleep 3600"],
    }],
}))
PY
aws ecs register-task-definition --cli-input-json "file:///tmp/vpce-td-${FAMILY}.json" >/dev/null

run_task() {
	local subnet="$1" sg="$2"
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[${subnet}],securityGroups=[${sg}],assignPublicIp=ENABLED}" \
		--query 'tasks[0].taskArn' --output text
}

wait_task() {
	local arn="$1" status=""
	for _ in $(seq 1 60); do
		status="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].lastStatus' --output text)"
		echo "task ${arn##*/} ${status}"
		[[ "$status" == "RUNNING" ]] && return 0
		[[ "$status" == "STOPPED" ]] && fail "task ${arn} stopped"
		sleep 2
	done
	fail "task ${arn} not running"
}

cid_for() {
	docker ps -q --filter "label=localemu.task-arn=$1" | head -1
}

TASK_A="$(run_task "$SUB_A" "$SG_A")"
TASK_B="$(run_task "$SUB_B" "$SG_B")"
wait_task "$TASK_A"
wait_task "$TASK_B"
sleep 2

CID_A="$(cid_for "$TASK_A")"
CID_B="$(cid_for "$TASK_B")"
[[ -n "$CID_A" ]] || fail "no docker container for task A"
[[ -n "$CID_B" ]] || fail "no docker container for task B"

echo "---- resolv A ----"
docker exec "$CID_A" cat /etc/resolv.conf >&2 || true
echo "---- resolv B ----"
docker exec "$CID_B" cat /etc/resolv.conf >&2 || true

resolve_ips() {
	local ctr="$1" host="$2"
	docker exec "$ctr" getent hosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
}

for pair in "${SERVICES[@]}"; do
	host="${pair#*:}"
	want="${HOST_TO_IP[$host]}"
	got="$(resolve_ips "$CID_A" "$host" || true)"
	echo "A ${host} -> ${got:-<none>} (want ${want})"
	printf '%s\n' "$got" | grep -qx "$want" || fail "VPC A did not resolve ${host} to ${want} (got: ${got:-none})"

	# Any HTTP response from the proxy proves the call reached LocalEmu
	# (root GET may be empty 200 or 500 with a Host: amazonaws.com header).
	hdr="$(docker exec "$CID_A" wget -S -O /dev/null --timeout=4 "http://${host}:4566/" 2>&1 || true)"
	printf '%s\n' "$hdr" | grep -qiE 'HTTP/[0-9]|x-localemu|TwistedWeb' \
		|| fail "VPC A call to ${host}:4566 did not reach awsbox (${hdr:-none})"

	other="$(resolve_ips "$CID_B" "$host" || true)"
	echo "B ${host} -> ${other:-<none>}"
	if printf '%s\n' "$other" | grep -qx "$want"; then
		fail "VPC B resolved ${host} to VPC A endpoint IP ${want}"
	fi
done

echo "ok vpce private dns (ecr/logs/ssm/sts/ecs) in-VPC vs other-VPC"
