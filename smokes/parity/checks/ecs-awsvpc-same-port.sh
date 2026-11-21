#!/usr/bin/env bash
# Dual-target: two awsvpc tasks with the same containerPort/hostPort both run
# (#769). Real AWS: Fargate ENIs. Local: empty Docker PortBindings + VPC-peer curl.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
CLUSTER="sw-parity-sameport-${TS}"
FAMILY_A="sw-parity-sameport-a-${TS}"
FAMILY_B="sw-parity-sameport-b-${TS}"
PORT=8080
ACCT="$PARITY_ACCOUNT"
REGION="$PARITY_REGION"

VPC="" SUB="" SG="" IGW="" RTB=""
TASK_A="" TASK_B="" TD_A="" TD_B=""
EXEC_ROLE_ARN=""

# LIFO: first registered runs last — VPC/IGW first, tasks last-to-register.
on_cleanup '[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC"'
on_cleanup '[[ -n "$IGW" ]] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"'
on_cleanup '[[ -n "$RTB" && -n "$IGW" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"'
on_cleanup '[[ -n "$RTB" ]] && aws ec2 delete-route-table --route-table-id "$RTB"'
on_cleanup '[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB"'
on_cleanup '[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG"'
on_cleanup '[[ -n "$TD_A" ]] && aws ecs deregister-task-definition --task-definition "$TD_A"'
on_cleanup '[[ -n "$TD_B" ]] && aws ecs deregister-task-definition --task-definition "$TD_B"'
on_cleanup "aws ecs delete-cluster --cluster '$CLUSTER'"
on_cleanup '[[ -n "$TASK_A" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_A"; [[ -n "$TASK_B" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_B"; sleep 15'

if [[ "$PARITY_TARGET" == "real" ]]; then
	EXEC_ROLE_ARN="arn:aws:iam::${ACCT}:role/ecsTaskExecutionRole"
	aws iam get-role --role-name ecsTaskExecutionRole >/dev/null \
		|| parity_die "real needs iam role ecsTaskExecutionRole"
fi

echo "==> VPC + subnet + SG"
VPC="$(aws ec2 create-vpc --cidr-block 10.181.0.0/16 --query Vpc.VpcId --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support >/dev/null
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames >/dev/null
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.181.1.0/24 \
	--query Subnet.SubnetId --output text)"
aws ec2 modify-subnet-attribute --subnet-id "$SUB" --map-public-ip-on-launch >/dev/null
SG="$(aws ec2 create-security-group --group-name "sw-parity-sameport-${TS}" \
	--description "parity awsvpc same port" --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 >/dev/null

if [[ "$PARITY_TARGET" == "real" ]]; then
	IGW="$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
	aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" >/dev/null
	RTB="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
	aws ec2 create-route --route-table-id "$RTB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
	aws ec2 associate-route-table --route-table-id "$RTB" --subnet-id "$SUB" >/dev/null
fi

make_cdef() {
	local text="$1"
	PORT="$PORT" TEXT="$text" python3 - <<'PY'
import json, os
port = int(os.environ["PORT"])
text = os.environ["TEXT"]
print(json.dumps([{
    "name": "web",
    "image": "hashicorp/http-echo:1.0",
    "essential": True,
    "memory": 128,
    "command": ["-listen", f":{port}", "-text", text],
    "portMappings": [
        {"containerPort": port, "hostPort": port, "protocol": "tcp"}
    ],
}]))
PY
}

reg_td() {
	local family="$1" text="$2"
	local args=(
		ecs register-task-definition
		--family "$family"
		--requires-compatibilities FARGATE
		--network-mode awsvpc
		--cpu 256
		--memory 512
		--container-definitions "$(make_cdef "$text")"
		--query taskDefinition.taskDefinitionArn
		--output text
	)
	if [[ -n "$EXEC_ROLE_ARN" ]]; then
		args+=(--execution-role-arn "$EXEC_ROLE_ARN")
	fi
	aws "${args[@]}"
}

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
TD_A="$(reg_td "$FAMILY_A" "sameport-a-${TS}")"
TD_B="$(reg_td "$FAMILY_B" "sameport-b-${TS}")"

NET="awsvpcConfiguration={subnets=[${SUB}],securityGroups=[${SG}],assignPublicIp=ENABLED}"
TASK_A="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_A" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
TASK_B="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_B" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
[[ -n "$TASK_A" && "$TASK_A" != "None" ]] || parity_die "RunTask A empty"
[[ -n "$TASK_B" && "$TASK_B" != "None" ]] || parity_die "RunTask B empty"

task_fields() {
	local task="$1"
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --output json | python3 -c '
import json, sys
t = json.load(sys.stdin)["tasks"][0]
status = t.get("lastStatus") or ""
reason = t.get("stoppedReason") or ""
priv = ""
pub = ""
bindings = []
for c in t.get("containers") or []:
    for b in c.get("networkBindings") or []:
        if b.get("containerPort") is not None:
            bindings.append("%s->%s" % (b.get("containerPort"), b.get("hostPort")))
for a in t.get("attachments") or []:
    for d in a.get("details") or []:
        if d.get("name") == "privateIPv4Address" and d.get("value"):
            priv = d["value"]
        if d.get("name") == "networkInterfaceId" and d.get("value"):
            pass
for ni in (t.get("attachments") or []):
    pass
# public IP lives on the ENI association for Fargate assignPublicIp
print(status)
print(priv)
print(",".join(bindings))
print(reason)
print(t.get("taskArn") or "")
'
}

wait_running() {
	local label="$1" task="$2"
	local status="" priv="" bindings="" reason="" arn=""
	local i
	for i in $(seq 1 120); do
		mapfile -t info < <(task_fields "$task")
		status="${info[0]:-}"
		priv="${info[1]:-}"
		bindings="${info[2]:-}"
		reason="${info[3]:-}"
		arn="${info[4]:-}"
		if [[ "$status" == "RUNNING" && -n "$priv" ]]; then
			echo "$label status=${status} ip=${priv} bindings=${bindings}" >&2
			printf '%s\n' "$status" "$priv" "$bindings" "$arn"
			return 0
		fi
		if [[ "$status" == "STOPPED" && "$i" -gt 15 ]]; then
			parity_die "$label STOPPED early (${reason:-empty})"
		fi
		sleep 2
	done
	parity_die "$label never RUNNING (status=${status} reason=${reason})"
}

mapfile -t A < <(wait_running A "$TASK_A")
mapfile -t B < <(wait_running B "$TASK_B")
IP_A="${A[1]}"
BIND_A="${A[2]}"
ARN_A="${A[3]}"
IP_B="${B[1]}"
BIND_B="${B[2]}"
ARN_B="${B[3]}"

[[ "$IP_A" != "$IP_B" ]] || parity_die "expected distinct ENI IPs, both ${IP_A}"
# Real Fargate often omits networkBindings on awsvpc; LocalEmu reports hostPort=containerPort.
if [[ "$PARITY_TARGET" == "local" ]]; then
	echo "$BIND_A" | grep -q "${PORT}->${PORT}" || parity_die "A missing ${PORT}->${PORT} (${BIND_A})"
	echo "$BIND_B" | grep -q "${PORT}->${PORT}" || parity_die "B missing ${PORT}->${PORT} (${BIND_B})"
	parity_pass "two awsvpc tasks RUNNING on distinct IPs with DescribeTasks bindings"
else
	parity_pass "two awsvpc tasks RUNNING on distinct ENI IPs (real omits networkBindings)"
fi

if [[ "$PARITY_TARGET" == "local" ]]; then
	for arn in "$ARN_A" "$ARN_B"; do
		ctr="$(docker ps --filter "label=localemu.task-arn=${arn}" --format '{{.Names}}' | head -1)"
		[[ -n "$ctr" ]] || parity_die "no docker container for ${arn}"
		pb="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$ctr")"
		[[ "$pb" == "null" || "$pb" == "{}" || "$pb" == "map[]" ]] \
			|| parity_die "expected empty PortBindings on ${ctr}, got ${pb}"
	done
	parity_pass "local: Docker PortBindings empty for awsvpc"

	VPC_NET="localemu-vpc-${VPC}"
	BODY_A="" BODY_B=""
	for _ in $(seq 1 40); do
		BODY_A="$(docker run --rm --network "$VPC_NET" curlimages/curl:8.5.0 \
			-sf -m 5 "http://${IP_A}:${PORT}/" 2>/dev/null || true)"
		BODY_B="$(docker run --rm --network "$VPC_NET" curlimages/curl:8.5.0 \
			-sf -m 5 "http://${IP_B}:${PORT}/" 2>/dev/null || true)"
		[[ "$BODY_A" == *"sameport-a-${TS}"* && "$BODY_B" == *"sameport-b-${TS}"* ]] && break
		sleep 1
	done
	[[ "$BODY_A" == *"sameport-a-${TS}"* ]] || parity_die "A not reachable on VPC (${BODY_A})"
	[[ "$BODY_B" == *"sameport-b-${TS}"* ]] || parity_die "B not reachable on VPC (${BODY_B})"
	parity_pass "local: VPC-peer curl both tasks"
else
	# Public IP via ENI association (assignPublicIp=ENABLED)
	pub_for() {
		local task="$1"
		aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --output json | python3 -c '
import json, sys, subprocess, os
t = json.load(sys.stdin)["tasks"][0]
eni = ""
for a in t.get("attachments") or []:
    for d in a.get("details") or []:
        if d.get("name") == "networkInterfaceId":
            eni = d.get("value") or ""
if not eni:
    print("")
    raise SystemExit
# Call aws from env PARITY — use subprocess with inherited env (already real)
out = subprocess.check_output(
    ["aws", "ec2", "describe-network-interfaces", "--network-interface-ids", eni,
     "--region", os.environ["AWS_DEFAULT_REGION"],
     "--query", "NetworkInterfaces[0].Association.PublicIp", "--output", "text"],
    text=True,
).strip()
print("" if out in ("None", "null") else out)
'
	}
	PUB_A="$(pub_for "$TASK_A")"
	PUB_B="$(pub_for "$TASK_B")"
	[[ -n "$PUB_A" && -n "$PUB_B" ]] || parity_die "missing public IPs A=${PUB_A} B=${PUB_B}"
	BODY_A="" BODY_B=""
	for _ in $(seq 1 60); do
		BODY_A="$(curl -sf -m 5 "http://${PUB_A}:${PORT}/" 2>/dev/null || true)"
		BODY_B="$(curl -sf -m 5 "http://${PUB_B}:${PORT}/" 2>/dev/null || true)"
		[[ "$BODY_A" == *"sameport-a-${TS}"* && "$BODY_B" == *"sameport-b-${TS}"* ]] && break
		sleep 2
	done
	[[ "$BODY_A" == *"sameport-a-${TS}"* ]] || parity_die "A not reachable on public ${PUB_A} (${BODY_A})"
	[[ "$BODY_B" == *"sameport-b-${TS}"* ]] || parity_die "B not reachable on public ${PUB_B} (${BODY_B})"
	parity_pass "real: public curl both Fargate tasks same hostPort"
fi

parity_finish
