#!/usr/bin/env bash
# Private hosted zone: associated VPC resolves and connects; the other VPC does not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

HOST_PORT="${AWSBOX_R53_HOST_PORT:-24566}"
EP="${AWSBOX_R53_ENDPOINT:-http://127.0.0.1:${HOST_PORT}}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_R53_KEEP:-0}"
RECREATE="${AWSBOX_R53_RECREATE:-1}"
# Extra compose file, e.g. to blank start.d hooks while #299 breaks EC2 containers.
COMPOSE=(-f "$ROOT/docker-compose.yml")
[[ -n "${AWSBOX_R53_COMPOSE_OVERRIDE:-}" ]] && COMPOSE+=(-f "$AWSBOX_R53_COMPOSE_OVERRIDE")
CREDS_PORT="${AWSBOX_R53_ECS_CREDS_PORT:-24571}"
ZONE_NAME="awsbox-${TS}.internal"
CLUSTER="r53-${TS}"
FAMILY_T="r53-tgt-${TS}"
FAMILY_C="r53-cli-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_LOCALEMU_HOST_PORT="$HOST_PORT"
export AWSBOX_ECS_CREDS_PORT="$CREDS_PORT"
export AWSBOX_SECRET_KEY="$SECRET"
export AWSBOX_ACCESS_KEY="$KEY"

VPC_A=""
VPC_B=""
SUB_A1=""
SUB_A2=""
SUB_B=""
SG_A=""
SG_B=""
ZONE_ID=""
NLB=""
ALB=""
TG_N=""
TG_A=""
TASK_T=""
TASK_OK=""
TASK_NO=""
IID=""
DENY_USER=""
DENY_KEY=""
POLICY_ARN=""
NLB_DNS=""
ALB_DNS=""
LS=""

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
	[[ -n "$TASK_T" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_T" >/dev/null 2>&1
	[[ -n "$TASK_OK" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_OK" >/dev/null 2>&1
	[[ -n "$TASK_NO" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_NO" >/dev/null 2>&1
	[[ -n "$IID" ]] && aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1
	[[ -n "$NLB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$NLB" >/dev/null 2>&1
	[[ -n "$ALB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" >/dev/null 2>&1
	sleep 2
	[[ -n "$TG_N" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_N" >/dev/null 2>&1
	[[ -n "$TG_A" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_A" >/dev/null 2>&1
	if [[ -n "$ZONE_ID" ]]; then
		python3 - "$ZONE_ID" "$EP" "$REGION" <<'PY' || true
import json, subprocess, sys
zone, ep, region = sys.argv[1:]
out = subprocess.check_output([
    "aws", "--endpoint-url", ep, "--region", region,
    "route53", "list-resource-record-sets", "--hosted-zone-id", zone, "--output", "json",
], text=True)
changes = []
for rr in json.loads(out).get("ResourceRecordSets") or []:
    if rr.get("Type") in {"NS", "SOA"}:
        continue
    changes.append({"Action": "DELETE", "ResourceRecordSet": rr})
if changes:
    subprocess.call([
        "aws", "--endpoint-url", ep, "--region", region, "route53",
        "change-resource-record-sets", "--hosted-zone-id", zone,
        "--change-batch", json.dumps({"Changes": changes}),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
		aws route53 delete-hosted-zone --id "$ZONE_ID" >/dev/null 2>&1
	fi
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1
	[[ -n "$SUB_A1" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A1" >/dev/null 2>&1
	[[ -n "$SUB_A2" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A2" >/dev/null 2>&1
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1
	[[ -n "$VPC_A" ]] && aws ec2 delete-vpc --vpc-id "$VPC_A" >/dev/null 2>&1
	[[ -n "$VPC_B" ]] && aws ec2 delete-vpc --vpc-id "$VPC_B" >/dev/null 2>&1
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1
	if [[ -n "$POLICY_ARN" && -n "$DENY_USER" ]]; then
		aws iam detach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1
		aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1
	fi
	if [[ -n "$DENY_KEY" && -n "$DENY_USER" ]]; then
		aws iam delete-access-key --user-name "$DENY_USER" --access-key-id "$DENY_KEY" >/dev/null 2>&1
	fi
	[[ -n "$DENY_USER" ]] && aws iam delete-user --user-name "$DENY_USER" >/dev/null 2>&1
	exit "$rc"
}
trap cleanup EXIT

echo "endpoint ${EP}"
if [[ "$RECREATE" == "1" ]]; then
	docker compose "${COMPOSE[@]}" up -d --force-recreate --no-deps localstack
else
	docker compose "${COMPOSE[@]}" up -d --no-deps localstack
fi
for _ in $(seq 1 90); do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
	[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && break
	sleep 2
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
[[ "$code" =~ ^[12345][0-9][0-9]$ ]] || fail "LocalEmu not ready at ${EP} (${code})"

LS="$(docker compose "${COMPOSE[@]}" ps -q localstack)"
[[ -n "$LS" ]] || fail "localstack container missing"
for _ in $(seq 1 40); do
	docker exec "$LS" grep -q "private DNS resolver starting" /tmp/vpce-resolver.log 2>/dev/null && break
	sleep 1
done
docker exec "$LS" grep -q "private DNS resolver starting" /tmp/vpce-resolver.log \
	|| fail "resolver did not start ($(docker exec "$LS" cat /tmp/vpce-resolver.log 2>/dev/null | tail -20))"

VPC_A="$(aws ec2 create-vpc --cidr-block 10.206.0.0/16 --query 'Vpc.VpcId' --output text)"
VPC_B="$(aws ec2 create-vpc --cidr-block 10.207.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A1="$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.206.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_A2="$(aws ec2 create-subnet --vpc-id "$VPC_A" --cidr-block 10.206.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC_B" --cidr-block 10.207.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SG_A="$(aws ec2 create-security-group --group-name "r53a-${TS}" --description r53 --vpc-id "$VPC_A" --query 'GroupId' --output text)"
SG_B="$(aws ec2 create-security-group --group-name "r53b-${TS}" --description r53 --vpc-id "$VPC_B" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_A" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_B" --protocol -1 --cidr 0.0.0.0/0 >/dev/null
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

register_td() {
	local family="$1" image="$2" cmd="$3"
	local file="/tmp/r53-td-${family}.json"
	python3 - "$family" "$image" "$cmd" >"$file" <<'PY'
import json, sys
family, image, cmd = sys.argv[1:]
container = {
    "name": "main",
    "image": image,
    "essential": True,
    "memory": 128,
}
if cmd:
    container["command"] = cmd.split()
print(json.dumps({
    "family": family,
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "containerDefinitions": [container],
}))
PY
	aws ecs register-task-definition --cli-input-json "file://${file}" >/dev/null
}

run_task() {
	local family="$1" subnet="$2" sg="$3"
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$family" \
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

register_td "$FAMILY_T" "nginx:1.27-alpine" ""
register_td "$FAMILY_C" "python:3.12-alpine" "sleep 3600"

TASK_T="$(run_task "$FAMILY_T" "$SUB_A1" "$SG_A")"
wait_task "$TASK_T"
CID_T=""
for _ in $(seq 1 30); do
	CID_T="$(cid_for "$TASK_T")"
	[[ -n "$CID_T" ]] && break
	sleep 1
done
[[ -n "$CID_T" ]] || fail "target container missing"
TIP=""
for _ in $(seq 1 20); do
	TIP="$(docker inspect "$CID_T" | python3 -c 'import json,sys; nets=json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]; print(next((info.get("IPAddress") or "" for name, info in nets.items() if name.startswith("localemu-vpc-")), ""))')"
	[[ -n "$TIP" ]] && break
	sleep 1
done
[[ -n "$TIP" ]] || fail "target has no VPC address"
echo "target ${CID_T} ${TIP}"

NLB="$(aws elbv2 create-load-balancer --name "r53n${TS}" --type network --scheme internal --subnets "$SUB_A1" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
ALB="$(aws elbv2 create-load-balancer --name "r53a${TS}" --type application --scheme internal --subnets "$SUB_A1" "$SUB_A2" --security-groups "$SG_A" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
NLB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB" --query 'LoadBalancers[0].DNSName' --output text)"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" --query 'LoadBalancers[0].DNSName' --output text)"
echo "NLB ${NLB_DNS}"
echo "ALB ${ALB_DNS}"
TG_N="$(aws elbv2 create-target-group --name "r53n${TS}" --protocol TCP --port 80 --vpc-id "$VPC_A" --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)"
TG_A="$(aws elbv2 create-target-group --name "r53a${TS}" --protocol HTTP --port 80 --vpc-id "$VPC_A" --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG_N" --targets "Id=${TIP},Port=80"
aws elbv2 register-targets --target-group-arn "$TG_A" --targets "Id=${TIP},Port=80"
aws elbv2 create-listener --load-balancer-arn "$NLB" --protocol TCP --port 80 --default-actions "Type=forward,TargetGroupArn=${TG_N}" >/dev/null
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 8080 --default-actions "Type=forward,TargetGroupArn=${TG_A}" >/dev/null

ZONE_ID="$(aws route53 create-hosted-zone \
	--name "$ZONE_NAME" \
	--caller-reference "r53-${TS}" \
	--hosted-zone-config "PrivateZone=true,Comment=awsbox" \
	--vpc "VPCRegion=${REGION},VPCId=${VPC_A}" \
	--query 'HostedZone.Id' --output text)"
echo "zone ${ZONE_ID}"

CHANGE="/tmp/r53-change-${TS}.json"
python3 - "$ZONE_NAME" "$NLB_DNS" "$ALB_DNS" >"$CHANGE" <<'PY'
import json, sys
zone, nlb, alb = sys.argv[1:]
def rr(name, typ, **extra):
    item = {"Name": f"{name}.{zone}.", "Type": typ}
    item.update(extra)
    return {"Action": "UPSERT", "ResourceRecordSet": item}
print(json.dumps({"Changes": [
    rr("app", "CNAME", TTL=30, ResourceRecords=[{"Value": nlb}]),
    rr("alb", "A", AliasTarget={
        "HostedZoneId": "Z35SXDOTRQ7X7K",
        "DNSName": alb if alb.endswith(".") else alb + ".",
        "EvaluateTargetHealth": False,
    }),
    rr("a", "A", TTL=30, ResourceRecords=[{"Value": "203.0.113.10"}]),
    rr("v6", "AAAA", TTL=30, ResourceRecords=[{"Value": "2001:db8::206"}]),
]}))
PY
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://${CHANGE}" >/dev/null

TASK_OK="$(run_task "$FAMILY_C" "$SUB_A1" "$SG_A")"
TASK_NO="$(run_task "$FAMILY_C" "$SUB_B" "$SG_B")"
wait_task "$TASK_OK"
wait_task "$TASK_NO"
CID_OK=""
CID_NO=""
for _ in $(seq 1 30); do
	CID_OK="$(cid_for "$TASK_OK")"
	CID_NO="$(cid_for "$TASK_NO")"
	[[ -n "$CID_OK" && -n "$CID_NO" ]] && break
	sleep 1
done
[[ -n "$CID_OK" && -n "$CID_NO" ]] || fail "client containers missing (${CID_OK:-none} ${CID_NO:-none})"

CHECK="/tmp/r53-check-${TS}.py"
cat >"$CHECK" <<'PY'
import ipaddress, os, socket, sys, urllib.request

mode = os.environ["MODE"]
zone = os.environ["ZONE"]
nlb = os.environ["NLB"]
alb = os.environ["ALB"]

def ips(name, family):
    return sorted({item[4][0] for item in socket.getaddrinfo(name, 80, family)})

def must_fail(name):
    try:
        socket.getaddrinfo(name, 80)
    except socket.gaierror:
        print(f"nxdomain {name}")
        return
    sys.exit(f"resolved {name} from unassociated VPC")

if mode == "deny":
    for name in (f"app.{zone}", f"alb.{zone}", f"a.{zone}", f"v6.{zone}", nlb):
        must_fail(name)
    sys.exit(0)

app = ips(f"app.{zone}", socket.AF_INET)
direct = ips(nlb, socket.AF_INET)
if not app or app != direct:
    sys.exit(f"cname {app} != nlb {direct}")
alias = ips(f"alb.{zone}", socket.AF_INET)
alb_ips = ips(alb, socket.AF_INET)
if not alias or alias != alb_ips:
    sys.exit(f"alias {alias} != alb {alb_ips}")
a = ips(f"a.{zone}", socket.AF_INET)
if a != ["203.0.113.10"]:
    sys.exit(f"A {a}")
v6 = [ipaddress.ip_address(item).compressed for item in ips(f"v6.{zone}", socket.AF_INET6)]
if "2001:db8::206" not in v6:
    sys.exit(f"AAAA {v6}")
body = urllib.request.urlopen(f"http://app.{zone}/", timeout=10).read()
if b"nginx" not in body.lower() and b"welcome" not in body.lower():
    sys.exit("connect body was not nginx")
print("ok", app[0], "alias", alias[0])
PY
docker cp "$CHECK" "${CID_OK}:/tmp/r53-check.py"
docker cp "$CHECK" "${CID_NO}:/tmp/r53-check.py"

ok_out=""
for _ in $(seq 1 25); do
	if ok_out="$(docker exec -e MODE=ok -e ZONE="$ZONE_NAME" -e NLB="$NLB_DNS" -e ALB="$ALB_DNS" "$CID_OK" python /tmp/r53-check.py 2>&1)"; then
		break
	fi
	echo "retry associated: ${ok_out}"
	ok_out=""
	sleep 2
done
[[ -n "$ok_out" ]] || fail "associated VPC did not resolve and connect"
echo "associated ${ok_out}"

docker exec -e MODE=deny -e ZONE="$ZONE_NAME" -e NLB="$NLB_DNS" -e ALB="$ALB_DNS" "$CID_NO" python /tmp/r53-check.py \
	|| fail "unassociated VPC resolved a private name"

echo "OK: private zone from ${VPC_A}; denied from ${VPC_B}"

IID="$(aws ec2 run-instances \
	--image-id ami-ubuntu-22.04 \
	--instance-type t2.micro \
	--subnet-id "$SUB_A1" \
	--security-group-ids "$SG_A" \
	--query 'Instances[0].InstanceId' --output text)"
echo "ec2 ${IID}"
EC2_STATE=""
for _ in $(seq 1 45); do
	EC2_STATE="$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text)"
	[[ "$EC2_STATE" == "running" ]] && break
	sleep 2
done
[[ "$EC2_STATE" == "running" ]] || fail "ec2 ${EC2_STATE}"
EC2_CID=""
for _ in $(seq 1 30); do
	EC2_CID="$(docker ps -q --filter "label=localemu.instance-id=${IID}" | head -1)"
	[[ -n "$EC2_CID" ]] && break
	sleep 2
done
[[ -n "$EC2_CID" ]] || fail "ec2 container missing"
docker cp "$CHECK" "${EC2_CID}:/tmp/r53-check.py"
ec2_out=""
for _ in $(seq 1 20); do
	if ec2_out="$(docker exec -e MODE=ok -e ZONE="$ZONE_NAME" -e NLB="$NLB_DNS" -e ALB="$ALB_DNS" "$EC2_CID" python3 /tmp/r53-check.py 2>&1)"; then
		break
	fi
	echo "retry ec2: ${ec2_out}"
	ec2_out=""
	sleep 2
done
[[ -n "$ec2_out" ]] || fail "EC2 in the associated VPC did not resolve"
echo "ec2 ${ec2_out}"

DENY_USER="r53-deny-${TS}"
aws iam create-user --user-name "$DENY_USER" >/dev/null
POLICY_DOC="/tmp/r53-deny-${TS}.json"
cat >"$POLICY_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Deny",
    "Action": "route53:ListHostedZones",
    "Resource": "*"
  }]
}
EOF
POLICY_ARN="$(aws iam create-policy --policy-name "r53-deny-${TS}" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$DENY_USER" --output json)"
DENY_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$KEYS_JSON")"
DENY_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$KEYS_JSON")"
set +e
DENY_OUT="$(
	AWS_ACCESS_KEY_ID="$DENY_KEY" AWS_SECRET_ACCESS_KEY="$DENY_SECRET" \
		command aws --endpoint-url "$EP" --region "$REGION" route53 list-hosted-zones 2>&1
)"
DENY_RC=$?
set -e
if [[ "$DENY_RC" -eq 0 ]]; then
	fail "route53 list-hosted-zones succeeded for deny user"
fi
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized' \
	|| fail "expected AccessDenied, got: ${DENY_OUT}"
echo "OK: route53 ListHostedZones denied"

echo "OK: r53 private zones (${ZONE_NAME})"
