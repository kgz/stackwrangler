#!/usr/bin/env bash
# #769: two awsvpc task defs both mapping containerPort/hostPort 8080 can run
# together; each answers on its VPC ENI address; DescribeTasks still reports
# networkBindings; Docker HostConfig.PortBindings stays empty (no host publish).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
CLUSTER="awsbox-ecs-sameport-${TS}"
FAMILY_A="awsbox-sameport-a-${TS}"
FAMILY_B="awsbox-sameport-b-${TS}"
PORT=8080

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

VPC="" SUB="" SG="" TASK_A="" TASK_B="" TD_A="" TD_B=""

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$TASK_A" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_A" >/dev/null 2>&1 || true
	[[ -n "$TASK_B" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_B" >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$TD_A" ]] && aws ecs deregister-task-definition --task-definition "$TD_A" >/dev/null 2>&1 || true
	[[ -n "$TD_B" ]] && aws ecs deregister-task-definition --task-definition "$TD_B" >/dev/null 2>&1 || true
	sleep 1
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

fail() { echo "FAIL: $*" >&2; exit 1; }

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

echo "==> VPC ${VPC_CIDR} / ${SUB_CIDR}"
VPC="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --query Vpc.VpcId --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$SUB_CIDR" --query Subnet.SubnetId --output text)"
SG="$(aws ec2 create-security-group --group-name "sameport-${TS}" --description "ecs same-port" --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 >/dev/null

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

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
TD_A="$(aws ecs register-task-definition --family "$FAMILY_A" --requires-compatibilities FARGATE \
	--network-mode awsvpc --cpu 256 --memory 512 --container-definitions "$(make_cdef "sameport-a-${TS}")" \
	--query taskDefinition.taskDefinitionArn --output text)"
TD_B="$(aws ecs register-task-definition --family "$FAMILY_B" --requires-compatibilities FARGATE \
	--network-mode awsvpc --cpu 256 --memory 512 --container-definitions "$(make_cdef "sameport-b-${TS}")" \
	--query taskDefinition.taskDefinitionArn --output text)"

NET="awsvpcConfiguration={subnets=[${SUB}],securityGroups=[${SG}],assignPublicIp=ENABLED}"

TASK_A="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_A" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
TASK_B="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_B" --launch-type FARGATE \
	--network-configuration "$NET" --query 'tasks[0].taskArn' --output text)"
[[ -n "$TASK_A" && "$TASK_A" != "None" ]] || fail "RunTask A returned no taskArn"
[[ -n "$TASK_B" && "$TASK_B" != "None" ]] || fail "RunTask B returned no taskArn"
echo "TASK_A=${TASK_A}"
echo "TASK_B=${TASK_B}"

task_info() {
	local task="$1"
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --output json | python3 -c '
import json, sys, subprocess
t = json.load(sys.stdin)["tasks"][0]
status = t.get("lastStatus") or ""
reason = t.get("stoppedReason") or ""
arn = t.get("taskArn") or ""
ip = ""
bindings = []
for c in t.get("containers") or []:
    for b in c.get("networkBindings") or []:
        if b.get("containerPort") is not None:
            bindings.append("%s->%s" % (b.get("containerPort"), b.get("hostPort")))
for a in t.get("attachments") or []:
    for d in a.get("details") or []:
        if d.get("name") == "privateIPv4Address" and d.get("value"):
            ip = d["value"]
ctr = ""
if arn:
    try:
        names = subprocess.check_output(
            ["docker", "ps", "--filter", "label=localemu.task-arn=%s" % arn,
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
print(",".join(bindings))
print(reason)
'
}

wait_running() {
	local label="$1" task="$2"
	local status="" ip="" ctr="" bindings="" reason=""
	local i
	for i in $(seq 1 90); do
		mapfile -t info < <(task_info "$task")
		status="${info[0]:-}"
		ip="${info[1]:-}"
		ctr="${info[2]:-}"
		bindings="${info[3]:-}"
		reason="${info[4]:-}"
		if [[ "$status" == "RUNNING" && -n "$ip" && -n "$ctr" ]]; then
			echo "$label status=${status} ip=${ip} ctr=${ctr} bindings=${bindings}" >&2
			printf '%s\n' "$status" "$ip" "$ctr" "$bindings"
			return 0
		fi
		if [[ "$status" == "STOPPED" && "$i" -gt 8 ]]; then
			fail "$label stopped early (reason=${reason:-empty})"
		fi
		sleep 1
	done
	fail "$label never RUNNING (status=${status} reason=${reason})"
}

mapfile -t A < <(wait_running A "$TASK_A")
mapfile -t B < <(wait_running B "$TASK_B")
IP_A="${A[1]}"
CTR_A="${A[2]}"
BIND_A="${A[3]}"
IP_B="${B[1]}"
CTR_B="${B[2]}"
BIND_B="${B[3]}"

[[ "$IP_A" != "$IP_B" ]] || fail "expected distinct VPC addresses, both ${IP_A}"
echo "$BIND_A" | grep -q "${PORT}->${PORT}" || fail "DescribeTasks A missing ${PORT}->${PORT} bindings (${BIND_A})"
echo "$BIND_B" | grep -q "${PORT}->${PORT}" || fail "DescribeTasks B missing ${PORT}->${PORT} bindings (${BIND_B})"

for ctr in "$CTR_A" "$CTR_B"; do
	pb="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$ctr")"
	[[ "$pb" == "null" || "$pb" == "{}" || "$pb" == "map[]" ]] \
		|| fail "expected empty PortBindings on ${ctr}, got ${pb}"
done

# Reach each task on its ENI from a peer on the same VPC bridge (host→ENI
# is often filtered; real consumers are ALB/NLB/Cloud Map/peers in-VPC).
VPC_NET="localemu-vpc-${VPC}"
BODY_A="" BODY_B=""
for _ in $(seq 1 30); do
	BODY_A="$(docker run --rm --network "$VPC_NET" curlimages/curl:8.5.0 \
		-sf -m 5 "http://${IP_A}:${PORT}/" 2>/dev/null || true)"
	BODY_B="$(docker run --rm --network "$VPC_NET" curlimages/curl:8.5.0 \
		-sf -m 5 "http://${IP_B}:${PORT}/" 2>/dev/null || true)"
	[[ "$BODY_A" == *"sameport-a-${TS}"* && "$BODY_B" == *"sameport-b-${TS}"* ]] && break
	sleep 1
done
[[ "$BODY_A" == *"sameport-a-${TS}"* ]] || fail "A not reachable at ${IP_A}:${PORT} from VPC peer (body=${BODY_A})"
[[ "$BODY_B" == *"sameport-b-${TS}"* ]] || fail "B not reachable at ${IP_B}:${PORT} from VPC peer (body=${BODY_B})"

echo "OK: two awsvpc tasks on :${PORT} at ${IP_A} and ${IP_B} (no host PortBindings)"
