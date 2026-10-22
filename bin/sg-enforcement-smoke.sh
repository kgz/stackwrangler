#!/usr/bin/env bash
# Security group enforcement (#205).
# Target allows TCP 8080 only from SG A: A (EC2 and ECS) connects, B is refused.
# Revoke/authorize without recreating the target flips the result.
# A prefix list and a CIDR of A's address do the same.
# RDS allows 5432 only from SG A.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_SG_KEEP:-0}"
PORT=8080

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

VPC="" SUB="" SG_T="" SG_A="" SG_B="" SG_RDS=""
INST_T="" INST_A="" INST_B=""
CLUSTER="" FAMILY="" TASK_A="" TASK_B=""
RDS_ID="" SUBNET_GROUP="" PL=""
WORKDIR=""

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$TASK_A" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_A" >/dev/null 2>&1 || true
	[[ -n "$TASK_B" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_B" >/dev/null 2>&1 || true
	[[ -n "$INST_T" ]] && aws ec2 terminate-instances --instance-ids "$INST_T" >/dev/null 2>&1 || true
	[[ -n "$INST_A" ]] && aws ec2 terminate-instances --instance-ids "$INST_A" >/dev/null 2>&1 || true
	[[ -n "$INST_B" ]] && aws ec2 terminate-instances --instance-ids "$INST_B" >/dev/null 2>&1 || true
	[[ -n "$RDS_ID" ]] && aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	sleep 2
	[[ -n "$CLUSTER" ]] && aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$SUBNET_GROUP" ]] && aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" >/dev/null 2>&1 || true
	[[ -n "$SG_T" ]] && aws ec2 delete-security-group --group-id "$SG_T" >/dev/null 2>&1 || true
	[[ -n "$SG_A" ]] && aws ec2 delete-security-group --group-id "$SG_A" >/dev/null 2>&1 || true
	[[ -n "$SG_B" ]] && aws ec2 delete-security-group --group-id "$SG_B" >/dev/null 2>&1 || true
	[[ -n "$SG_RDS" ]] && aws ec2 delete-security-group --group-id "$SG_RDS" >/dev/null 2>&1 || true
	[[ -n "$PL" ]] && aws ec2 delete-managed-prefix-list --prefix-list-id "$PL" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	[[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

ctr() {
	echo "localemu-ec2-$1"
}

dump_sg() {
	local name="$1"
	echo "---- iptables $name ----" >&2
	docker exec "$name" iptables -S SG_IN >&2 || true
	docker exec "$name" iptables -S SG_OUT >&2 || true
}

# Prints "open" when TCP connects or is refused (the packet was delivered),
# "closed" when it times out (SG DROP).
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
' "$ip" "$port" || echo error
}

expect_open() {
	local name="$1" ip="$2" label="$3"
	local got
	got="$(tcp_result "$name" "$ip" "$PORT")"
	if [[ "$got" != "open" ]]; then
		echo "FAIL: $label expected allow, got $got ($name -> $ip:$PORT)" >&2
		dump_sg "$(ctr "$INST_T")"
		dump_sg "$name"
		exit 1
	fi
	echo "ok  $label"
}

expect_closed() {
	local name="$1" ip="$2" label="$3"
	local got
	got="$(tcp_result "$name" "$ip" "$PORT")"
	if [[ "$got" != "closed" ]]; then
		echo "FAIL: $label expected deny, got $got ($name -> $ip:$PORT)" >&2
		dump_sg "$(ctr "$INST_T")"
		exit 1
	fi
	echo "ok  $label"
}

expect_rds() {
	local name="$1" ip="$2" want="$3" label="$4"
	local got
	got="$(tcp_result "$name" "$ip" 5432)"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL: $label expected $want, got $got ($name -> $ip:5432)" >&2
		dump_sg "localemu-rds-${RDS_ID}"
		exit 1
	fi
	echo "ok  $label"
}

WORKDIR="$(mktemp -d)"
cat > "$WORKDIR/user-data.sh" <<EOF
#!/bin/sh
mkdir -p /var/lib/localemu
cat > /var/lib/localemu/awsbox-sg.py << 'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"sg-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("0.0.0.0", ${PORT}), Handler).serve_forever()
PY
nohup python3 /var/lib/localemu/awsbox-sg.py >/var/log/awsbox-sg.log 2>&1 &
exit 0
EOF

VPC="$(aws ec2 create-vpc --cidr-block 10.205.0.0/16 --query Vpc.VpcId --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.205.1.0/24 --query Subnet.SubnetId --output text)"
SG_T="$(aws ec2 create-security-group --group-name "awsbox-sg-t-${TS}" --description target --vpc-id "$VPC" --query GroupId --output text)"
SG_A="$(aws ec2 create-security-group --group-name "awsbox-sg-a-${TS}" --description caller-a --vpc-id "$VPC" --query GroupId --output text)"
SG_B="$(aws ec2 create-security-group --group-name "awsbox-sg-b-${TS}" --description caller-b --vpc-id "$VPC" --query GroupId --output text)"
SG_RDS="$(aws ec2 create-security-group --group-name "awsbox-sg-rds-${TS}" --description rds --vpc-id "$VPC" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_A" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" --protocol tcp --port 5432 --source-group "$SG_A" >/dev/null

run_ec2() {
	local sg="$1"
	local -a ud=()
	if [[ -n "${2:-}" ]]; then
		ud=(--user-data "file://${2}")
	fi
	aws ec2 run-instances --image-id ami-ubuntu-22.04 --instance-type t3.micro \
		--subnet-id "$SUB" --security-group-ids "$sg" \
		"${ud[@]}" \
		--query 'Instances[0].InstanceId' --output text
}

INST_T="$(run_ec2 "$SG_T" "$WORKDIR/user-data.sh")"
INST_A="$(run_ec2 "$SG_A")"
INST_B="$(run_ec2 "$SG_B")"

wait_up() {
	local iid="$1" need_http="${2:-0}"
	local state=""
	for _ in $(seq 1 45); do
		state="$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text)"
		if [[ "$state" == "running" ]] && docker exec "$(ctr "$iid")" true >/dev/null 2>&1; then
			if [[ "$need_http" == "0" ]]; then
				return 0
			fi
			if tcp_result "$(ctr "$iid")" 127.0.0.1 "$PORT" | grep -q open; then
				return 0
			fi
		fi
		sleep 2
	done
	echo "FAIL: ${iid} not ready (state=${state})" >&2
	docker logs "$(ctr "$iid")" 2>&1 | tail -40 >&2 || true
	exit 1
}

wait_up "$INST_T" 1
wait_up "$INST_A" 0
wait_up "$INST_B" 0
IP_T="$(aws ec2 describe-instances --instance-ids "$INST_T" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
IP_A="$(aws ec2 describe-instances --instance-ids "$INST_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
echo "target=${INST_T} ${IP_T}  A=${INST_A} ${IP_A}  B=${INST_B}"

expect_open "$(ctr "$INST_A")" "$IP_T" "EC2 in SG A allowed"
expect_closed "$(ctr "$INST_B")" "$IP_T" "EC2 in SG B refused"

CLUSTER="awsbox-sg-${TS}"
FAMILY="awsbox-sg-${TS}"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
aws ecs register-task-definition \
	--family "$FAMILY" \
	--network-mode awsvpc \
	--requires-compatibilities FARGATE \
	--cpu 256 \
	--memory 512 \
	--container-definitions '[{"name":"c","image":"python:3.12-alpine","essential":true,"command":["sleep","3600"]}]' \
	>/dev/null

run_task() {
	local sg="$1"
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" --launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[${SUB}],securityGroups=[${sg}],assignPublicIp=ENABLED}" \
		--query 'tasks[0].taskArn' --output text
}

TASK_A="$(run_task "$SG_A")"
TASK_B="$(run_task "$SG_B")"

ecs_name() {
	local arn="$1" name=""
	for _ in $(seq 1 30); do
		name="$(docker ps --filter "label=localemu.task-arn=${arn}" --format '{{.Names}}' | head -1 || true)"
		if [[ -n "$name" ]] && docker exec "$name" python3 -c 'print(1)' >/dev/null 2>&1; then
			echo "$name"
			return 0
		fi
		sleep 2
	done
	echo "FAIL: ECS task ${arn} container not usable" >&2
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --output json >&2 || true
	exit 1
}

ECS_A="$(ecs_name "$TASK_A")"
ECS_B="$(ecs_name "$TASK_B")"
expect_open "$ECS_A" "$IP_T" "ECS awsvpc in SG A allowed"
expect_closed "$ECS_B" "$IP_T" "ECS awsvpc in SG B refused"

SUBNET_GROUP="awsbox-sg-${TS}"
RDS_ID="awsboxsg${TS}"
aws rds create-db-subnet-group \
	--db-subnet-group-name "$SUBNET_GROUP" \
	--db-subnet-group-description awsbox \
	--subnet-ids "$SUB" >/dev/null
aws rds create-db-instance \
	--db-instance-identifier "$RDS_ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16 \
	--master-username awsbox \
	--master-user-password 'AwsboxRds1!' \
	--allocated-storage 20 \
	--db-subnet-group-name "$SUBNET_GROUP" \
	--vpc-security-group-ids "$SG_RDS" >/dev/null

RDS_IP=""
for _ in $(seq 1 30); do
	if docker ps --format '{{.Names}}' | grep -q "^localemu-rds-${RDS_ID}$"; then
		RDS_IP="$(docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"localemu-vpc-${VPC}\"}}{{\$v.IPAddress}}{{end}}{{end}}" "localemu-rds-${RDS_ID}")"
		[[ -n "$RDS_IP" ]] && break
	fi
	sleep 2
done
[[ -n "$RDS_IP" ]] || {
	echo "FAIL: RDS container has no VPC IP" >&2
	exit 1
}
expect_rds "$(ctr "$INST_A")" "$RDS_IP" open "RDS allows SG A"
expect_rds "$(ctr "$INST_B")" "$RDS_IP" closed "RDS refuses SG B"

aws ec2 revoke-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_A" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_B" >/dev/null
expect_closed "$(ctr "$INST_A")" "$IP_T" "after revoke, EC2 A refused without recreate"
expect_open "$(ctr "$INST_B")" "$IP_T" "after authorize, EC2 B allowed without recreate"
expect_closed "$ECS_A" "$IP_T" "after revoke, ECS A refused"
expect_open "$ECS_B" "$IP_T" "after authorize, ECS B allowed"

aws ec2 revoke-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --source-group "$SG_B" >/dev/null
PL="$(aws ec2 create-managed-prefix-list \
	--address-family IPv4 \
	--prefix-list-name "awsbox-sg-${TS}" \
	--max-entries 2 \
	--entries "Cidr=${IP_A}/32,Description=caller-a" \
	--query 'PrefixList.PrefixListId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_T" \
	--ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},PrefixListIds=[{PrefixListId=${PL}}]" >/dev/null
expect_open "$(ctr "$INST_A")" "$IP_T" "prefix list allows A"
expect_closed "$(ctr "$INST_B")" "$IP_T" "prefix list refuses B"

aws ec2 revoke-security-group-ingress --group-id "$SG_T" \
	--ip-permissions "IpProtocol=tcp,FromPort=${PORT},ToPort=${PORT},PrefixListIds=[{PrefixListId=${PL}}]" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_T" --protocol tcp --port "$PORT" --cidr "${IP_A}/32" >/dev/null
expect_open "$(ctr "$INST_A")" "$IP_T" "CIDR allows A"
expect_closed "$(ctr "$INST_B")" "$IP_T" "CIDR refuses B"

echo "OK: sg enforcement (${INST_T} / ${ECS_A} / ${RDS_ID})"
