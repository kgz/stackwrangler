#!/usr/bin/env bash
# #207: EC2-backed ECS services.
#   1) deny-user ecs:CreateService → AccessDenied
#   2) ASG (launch template) instance becomes the container instance
#   3) bridge service, desired 2, behind an internal NLB; kill one → replaced
#   4) task definition update rolls the tasks; an unstartable roll keeps the old
#      tasks and task definition, replaces a killed task on the old definition,
#      and a later good update recovers
#   5) CodeDeploy revision for a missing task def → Failed, listener unchanged
#   6) CODE_DEPLOY service starts blue tasks; blue/green launches v2 on green,
#      swaps the listener, stops blue; a killed green task is replaced
#
# Traffic goes through a 127.0.0.1 forwarder inside LocalEmu (not published on
# the host). The #203 VPC listener cannot reach bridge host ports yet (#247).
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
KEEP="${AWSBOX_ECS_EC2_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 180 "$@"
}

CLUSTER="awsbox-ecs-ec2-${TS}"
SVC="web-${TS}"
BG_SVC="bg-${TS}"
FAMILY="awsbox-ecs-ec2-${TS}"
BG_FAMILY="awsbox-ecs-bg-${TS}"
ASG="ecs-${TS}"
LT="ecs-lt-${TS}"
APP="ecs-bg-${TS}"
DG="ecs-bg-${TS}"
ROLE="awsbox-ecs-cd-${TS}"
DENY_USER="awsbox-ecs-deny-${TS}"
NLB_PORT=18080
BG_PORT=18081

VPC=""
SUB_A=""
SUB_B=""
IID=""
TG=""
TG_BLUE=""
TG_GREEN=""
LB=""
LB_BG=""
LIS=""
LIS_BG=""
LS=""
DENIED_KEY=""
POLICY_ARN=""
TMPDIR="${TMPDIR:-/tmp}/awsbox-ecs-ec2-$$"
mkdir -p "$TMPDIR"

fail() {
	echo "FAIL: $*" >&2
	aws ecs list-container-instances --cluster "$CLUSTER" >&2 || true
	aws elbv2 describe-target-health --target-group-arn "$TG" >&2 || true
	aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" >&2 || true
	aws elbv2 describe-target-health --target-group-arn "$TG_GREEN" >&2 || true
	aws elbv2 describe-listeners --listener-arns "$LIS_BG" >&2 || true
	exit 1
}

cleanup() {
	rm -rf "$TMPDIR"
	[[ "$KEEP" == "1" ]] && return 0
	aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --desired-count 0 >/dev/null 2>&1 || true
	aws ecs update-service --cluster "$CLUSTER" --service "$BG_SVC" --desired-count 0 >/dev/null 2>&1 || true
	aws ecs delete-service --cluster "$CLUSTER" --service "$SVC" --force >/dev/null 2>&1 || true
	aws ecs delete-service --cluster "$CLUSTER" --service "$BG_SVC" --force >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws deploy delete-deployment-group --application-name "$APP" --deployment-group-name "$DG" >/dev/null 2>&1 || true
	aws deploy delete-application --application-name "$APP" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	if [[ -n "$DENIED_KEY" ]]; then
		aws iam delete-access-key --user-name "$DENY_USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	fi
	if [[ -n "$POLICY_ARN" ]]; then
		aws iam detach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
		aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	fi
	aws iam delete-user --user-name "$DENY_USER" >/dev/null 2>&1 || true
	[[ -n "$LIS" ]] && aws elbv2 delete-listener --listener-arn "$LIS" >/dev/null 2>&1 || true
	[[ -n "$LIS_BG" ]] && aws elbv2 delete-listener --listener-arn "$LIS_BG" >/dev/null 2>&1 || true
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "$LB_BG" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB_BG" >/dev/null 2>&1 || true
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "$TG_BLUE" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_BLUE" >/dev/null 2>&1 || true
	[[ -n "$TG_GREEN" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_GREEN" >/dev/null 2>&1 || true
	aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete >/dev/null 2>&1 || true
	aws ec2 delete-launch-template --launch-template-name "$LT" >/dev/null 2>&1 || true
	[[ -n "$IID" ]] && aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

LS="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS" ]] || fail "LocalEmu is not up (docker compose up localstack)"

# 10.217/16 is a free Docker bridge slot on a host that already has other
# localemu-vpc networks. Reusing 10.207/16 collides and the in-container
# `docker` CLI is missing, so the fallback picker cannot see live subnets.
VPC="$(aws ec2 create-vpc --cidr-block 10.217.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

echo "==> deny ecs:CreateService"
cat >"$TMPDIR/deny.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Deny", "Action": "ecs:CreateService", "Resource": "*"}
  ]
}
EOF
aws iam create-user --user-name "$DENY_USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "AwsboxDenyEcsCreate-${TS}" --policy-document "file://${TMPDIR}/deny.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$DENY_USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
DENY_OUT="$(
	AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
		aws ecs create-service --cluster "$CLUSTER" --service-name "deny-${TS}" \
			--task-definition "$FAMILY" --desired-count 1 2>&1
)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || fail "CreateService succeeded for the deny user"
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized' \
	|| fail "expected AccessDenied, got: ${DENY_OUT}"
echo "OK: CreateService AccessDenied"

echo "==> container instance from an ASG (launch template)"
aws ec2 create-launch-template --launch-template-name "$LT" \
	--launch-template-data '{"ImageId":"ami-localemu-ecs","InstanceType":"t3.micro"}' >/dev/null
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG" \
	--launch-template "LaunchTemplateName=${LT},Version=\$Latest" \
	--min-size 1 --max-size 1 --desired-capacity 1 \
	--vpc-zone-identifier "$SUB_A" \
	--tags "Key=ecs:cluster,Value=${CLUSTER},PropagateAtLaunch=true"
for _ in $(seq 1 30); do
	IID="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
		--query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' --output text)"
	[[ -n "$IID" && "$IID" != "None" ]] && break
	sleep 2
done
[[ -n "$IID" && "$IID" != "None" ]] || fail "ASG launched no instance"
echo "instance=${IID}"

mk_tg() {
	local name="$1"
	aws elbv2 create-target-group --name "$name" --protocol TCP --port 80 \
		--vpc-id "$VPC" --target-type instance \
		--health-check-protocol TCP --health-check-port traffic-port \
		--query 'TargetGroups[0].TargetGroupArn' --output text
}

TG="$(mk_tg "w${TS}")"
TG_BLUE="$(mk_tg "b${TS}")"
TG_GREEN="$(mk_tg "g${TS}")"
LB="$(aws elbv2 create-load-balancer --name "n${TS}" --type network --scheme internal \
	--subnets "$SUB_A" "$SUB_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LB_BG="$(aws elbv2 create-load-balancer --name "b${TS}" --type network --scheme internal \
	--subnets "$SUB_A" "$SUB_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol TCP --port "$NLB_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" --query 'Listeners[0].ListenerArn' --output text)"
LIS_BG="$(aws elbv2 create-listener --load-balancer-arn "$LB_BG" --protocol TCP --port "$BG_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG_BLUE}" --query 'Listeners[0].ListenerArn' --output text)"

write_taskdef() {
	local family="$1" dest="$2" body="$3" image="${4:-nginx:1.27-alpine}"
	python3 - "$family" "$dest" "$body" "$image" <<'PY'
import json, sys
family, dest, body, image = sys.argv[1:]
doc = {
    "family": family,
    "networkMode": "bridge",
    "requiresCompatibilities": ["EC2"],
    "containerDefinitions": [{
        "name": "web",
        "image": image,
        "essential": True,
        "memory": 128,
        "portMappings": [{"containerPort": 80, "protocol": "tcp"}],
        "command": ["sh", "-c", body],
    }],
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

WEB_CMD='echo -n "$HOSTNAME" > /usr/share/nginx/html/index.html && exec nginx -g "daemon off;"'
V3_CMD='echo -n "v3-$HOSTNAME" > /usr/share/nginx/html/index.html && exec nginx -g "daemon off;"'
V2_CMD='echo -n "v2-$HOSTNAME" > /usr/share/nginx/html/index.html && exec nginx -g "daemon off;"'
write_taskdef "$FAMILY" "$TMPDIR/web.json" "$WEB_CMD"
write_taskdef "$FAMILY" "$TMPDIR/web2.json" "$V2_CMD"
write_taskdef "$FAMILY" "$TMPDIR/web3.json" "$V3_CMD"
write_taskdef "$FAMILY" "$TMPDIR/webbad.json" "$V2_CMD" "awsbox.invalid/no-such-image:latest"
write_taskdef "$BG_FAMILY" "$TMPDIR/bg.json" "$WEB_CMD"
write_taskdef "$BG_FAMILY" "$TMPDIR/bg2.json" "$V2_CMD"
TD1="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/web.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
TD_BG="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/bg.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
TD_BG2="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/bg2.json" --query 'taskDefinition.taskDefinitionArn' --output text)"

echo "==> bridge service desired 2"
aws ecs create-service --cluster "$CLUSTER" --service-name "$SVC" \
	--task-definition "$TD1" --desired-count 2 --launch-type EC2 \
	--load-balancers "targetGroupArn=${TG},containerName=web,containerPort=80" >/dev/null

CI_N="$(aws ecs list-container-instances --cluster "$CLUSTER" --query 'length(containerInstanceArns)' --output text)"
[[ "$CI_N" == "1" ]] || fail "expected 1 container instance, got ${CI_N}"
CI_ARN="$(aws ecs list-container-instances --cluster "$CLUSTER" --query 'containerInstanceArns[0]' --output text)"
CI_EC2="$(aws ecs describe-container-instances --cluster "$CLUSTER" --container-instances "$CI_ARN" --query 'containerInstances[0].ec2InstanceId' --output text)"
[[ "$CI_EC2" == "$IID" ]] || fail "container instance is ${CI_EC2}, ASG instance is ${IID}"
echo "OK: container instance ${CI_EC2}"

health_n() {
	aws elbv2 describe-target-health --target-group-arn "$1" \
		--query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}

wait_healthy() {
	local arn="$1" want="$2"
	local i n
	for i in $(seq 1 50); do
		n="$(health_n "$arn")"
		echo "health ${arn##*/} healthy=${n}"
		[[ "$n" == "$want" ]] && return 0
		sleep 2
	done
	aws elbv2 describe-target-health --target-group-arn "$arn" >&2 || true
	fail "target group did not reach ${want} healthy"
}

tg_ports() {
	aws elbv2 describe-target-health --target-group-arn "$1" \
		--query 'TargetHealthDescriptions[].Target.Port' --output text | tr '\t' '\n' | sort | tr '\n' ' '
}

tg_ids() {
	aws elbv2 describe-target-health --target-group-arn "$1" \
		--query 'TargetHealthDescriptions[].Target.Id' --output text | tr '\t' '\n' | sort -u
}

nlb_names() {
	local port="$1"
	docker exec -i "$LS" /opt/code/localemu/.venv/bin/python - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
names = []
for _ in range(12):
    s = socket.create_connection(("127.0.0.1", port), 5)
    s.sendall(b"GET / HTTP/1.0\r\nHost: nlb\r\nConnection: close\r\n\r\n")
    s.settimeout(5)
    data = b""
    while True:
        try:
            chunk = s.recv(4096)
        except Exception:
            break
        if not chunk:
            break
        data += chunk
    s.close()
    body = data.split(b"\r\n\r\n", 1)[-1].decode(errors="replace").strip()
    names.append(body.split()[0] if body else "")
print("\n".join(names))
PY
}

host_closed() {
	python3 - "$1" <<'PY'
import socket, sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()
except OSError:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

cid_for_name() {
	local want="$1" cid cluster
	while read -r cid cluster; do
		[[ -z "${cid:-}" ]] && continue
		[[ "$cluster" == *"$CLUSTER"* ]] || continue
		if [[ "$(docker exec "$cid" hostname 2>/dev/null || true)" == "$want" ]]; then
			echo "$cid"
			return 0
		fi
	done < <(docker ps --filter label=localemu.service=ecs --format '{{.ID}} {{.Label "localemu.cluster"}}')
	return 1
}

host_port_of() {
	docker port "$1" 80/tcp | head -1 | sed 's/.*://'
}

wait_healthy "$TG" 2
echo "$(tg_ids "$TG")" | grep -qx "$IID" || fail "targets are not the ASG instance"
PORTS_BEFORE="$(tg_ports "$TG")"
echo "ports=${PORTS_BEFORE}"
[[ "$(echo "$PORTS_BEFORE" | wc -w)" -eq 2 ]] || fail "expected 2 host ports (${PORTS_BEFORE})"
host_closed "$NLB_PORT" || fail "internal NLB accepted a connection on the host"
NAMES="$(nlb_names "$NLB_PORT")"
echo "$NAMES"
UNIQUE="$(echo "$NAMES" | sort -u | grep -c . || true)"
[[ "$UNIQUE" -eq 2 ]] || fail "NLB did not reach both tasks (${NAMES})"
echo "OK: internal NLB both tasks"

echo "==> kill one task"
VICTIM="$(echo "$NAMES" | head -1)"
CID="$(cid_for_name "$VICTIM")" || fail "no container for ${VICTIM}"
DEAD_PORT="$(host_port_of "$CID")"
docker kill "$CID" >/dev/null
echo "killed ${VICTIM} port ${DEAD_PORT}"
REPLACED=0
PORTS_AFTER=""
NAMES2=""
for _ in $(seq 1 40); do
	HN="$(health_n "$TG")"
	echo "health after kill healthy=${HN}"
	PORTS_AFTER="$(tg_ports "$TG")"
	if [[ "$HN" == "2" ]] && [[ "$(echo "$PORTS_AFTER" | wc -w)" -eq 2 ]] \
		&& ! echo " ${PORTS_AFTER} " | grep -q " ${DEAD_PORT} "; then
		NAMES2="$(nlb_names "$NLB_PORT" || true)"
		if ! echo "$NAMES2" | grep -qx "$VICTIM"; then
			UNIQUE2="$(echo "$NAMES2" | sort -u | grep -c . || true)"
			if [[ "$UNIQUE2" -eq 2 ]]; then
				REPLACED=1
				break
			fi
		fi
	fi
	sleep 2
done
[[ "$REPLACED" == "1" ]] || fail "task was not replaced (ports ${PORTS_AFTER:-?} names ${NAMES2:-})"
echo "$NAMES2"
echo "OK: replaced and re-registered"

echo "==> roll task definition"
TD2="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/web2.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --task-definition "$TD2" >/dev/null
ROLLED=0
NAMES3=""
for _ in $(seq 1 40); do
	HN="$(health_n "$TG")"
	echo "health roll healthy=${HN}"
	if [[ "$HN" == "2" ]]; then
		NAMES3="$(nlb_names "$NLB_PORT" || true)"
		V2N="$(echo "$NAMES3" | grep -c '^v2-' || true)"
		UNIQ3="$(echo "$NAMES3" | sort -u | grep -c . || true)"
		if [[ "$V2N" -eq 12 && "$UNIQ3" -eq 2 ]]; then
			ROLLED=1
			break
		fi
	fi
	sleep 2
done
[[ "$ROLLED" == "1" ]] || fail "roll did not land on v2 tasks (${NAMES3:-})"
echo "OK: rolled to ${TD2}"

echo "==> roll that cannot start keeps old tasks"
TD_BAD="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/webbad.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --task-definition "$TD_BAD" >/dev/null
svc_field() {
	aws ecs describe-services --cluster "$CLUSTER" --services "$SVC" --query "services[0].$1" --output text
}
[[ "$(svc_field taskDefinition)" == "$TD2" ]] || fail "failed roll reports $(svc_field taskDefinition), want ${TD2}"
[[ "$(svc_field runningCount)" == "2" ]] || fail "failed roll runningCount is $(svc_field runningCount)"
[[ "$(health_n "$TG")" == "2" ]] || fail "failed roll disturbed the target group"
NAMES_BAD="$(nlb_names "$NLB_PORT")"
[[ "$(echo "$NAMES_BAD" | grep -c '^v2-')" -eq 12 ]] || fail "failed roll changed what the NLB serves (${NAMES_BAD})"
echo "OK: failed roll kept v2 tasks and ${TD2}"

echo "==> kill a task while the roll is pending"
VICTIM2="$(echo "$NAMES_BAD" | head -1 | sed 's/^v2-//')"
CID2="$(cid_for_name "$VICTIM2")" || fail "no container for ${VICTIM2}"
docker kill "$CID2" >/dev/null
PEND_OK=0
for _ in $(seq 1 45); do
	HN="$(health_n "$TG")"
	echo "health pending-roll healthy=${HN}"
	if [[ "$HN" == "2" ]]; then
		NAMES_P="$(nlb_names "$NLB_PORT" || true)"
		if [[ "$(echo "$NAMES_P" | grep -c '^v2-')" -eq 12 ]] \
			&& ! echo "$NAMES_P" | grep -qx "v2-${VICTIM2}" \
			&& [[ "$(echo "$NAMES_P" | sort -u | grep -c .)" -eq 2 ]]; then
			PEND_OK=1
			break
		fi
	fi
	sleep 2
done
[[ "$PEND_OK" == "1" ]] || fail "killed task was not replaced on the active task definition (${NAMES_P:-})"
[[ "$(svc_field taskDefinition)" == "$TD2" ]] || fail "service reports $(svc_field taskDefinition) after replacement"
echo "OK: replacement used ${TD2}, not the unstartable definition"

echo "==> good update recovers"
TD3="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/web3.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
aws ecs update-service --cluster "$CLUSTER" --service "$SVC" --task-definition "$TD3" >/dev/null
RECOVERED=0
NAMES_R=""
for _ in $(seq 1 40); do
	HN="$(health_n "$TG")"
	echo "health recover healthy=${HN}"
	if [[ "$HN" == "2" ]]; then
		NAMES_R="$(nlb_names "$NLB_PORT" || true)"
		if [[ "$(echo "$NAMES_R" | grep -c '^v3-')" -eq 12 && "$(echo "$NAMES_R" | sort -u | grep -c .)" -eq 2 ]]; then
			RECOVERED=1
			break
		fi
	fi
	sleep 2
done
[[ "$RECOVERED" == "1" ]] || fail "service did not recover to v3 (${NAMES_R:-})"
[[ "$(svc_field taskDefinition)" == "$TD3" ]] || fail "service reports $(svc_field taskDefinition), want ${TD3}"
echo "OK: recovered on ${TD3}"

echo "==> CodeDeploy missing task definition"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws deploy create-application --application-name "$APP" --compute-platform ECS >/dev/null
python3 - "$TMPDIR/dg.json" "$APP" "$DG" "$ROLE_ARN" "$CLUSTER" "$BG_SVC" "$LIS_BG" "b${TS}" "g${TS}" <<'PY'
import json, sys
dest, app, dg, role, cluster, service, listener, blue, green = sys.argv[1:]
doc = {
    "applicationName": app,
    "deploymentGroupName": dg,
    "serviceRoleArn": role,
    "deploymentStyle": {"deploymentType": "BLUE_GREEN", "deploymentOption": "WITH_TRAFFIC_CONTROL"},
    "blueGreenDeploymentConfiguration": {
        "terminateBlueInstancesOnDeploymentSuccess": {"action": "TERMINATE", "terminationWaitTimeInMinutes": 0},
        "deploymentReadyOption": {"actionOnTimeout": "CONTINUE_DEPLOYMENT", "waitTimeInMinutes": 0},
    },
    "ecsServices": [{"serviceName": service, "clusterName": cluster}],
    "loadBalancerInfo": {
        "targetGroupPairInfoList": [{
            "targetGroups": [{"name": blue}, {"name": green}],
            "prodTrafficRoute": {"listenerArns": [listener]},
        }]
    },
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
aws deploy create-deployment-group --cli-input-json "file://${TMPDIR}/dg.json" >/dev/null
aws ecs create-service --cluster "$CLUSTER" --service-name "$BG_SVC" \
	--task-definition "$TD_BG" --desired-count 1 --launch-type EC2 \
	--deployment-controller type=CODE_DEPLOY \
	--load-balancers "targetGroupArn=${TG_BLUE},containerName=web,containerPort=80" >/dev/null

echo "==> CODE_DEPLOY service blue tasks"
# The CODE_DEPLOY service must run its own blue task before any deployment.
wait_healthy "$TG_BLUE" 1
BLUE_NAME="$(nlb_names "$BG_PORT" | sort -u | head -1)"
[[ -n "$BLUE_NAME" && "$BLUE_NAME" != v2-* ]] || fail "blue NLB name is '${BLUE_NAME}'"
BLUE_CID="$(cid_for_name "$BLUE_NAME")" || fail "no blue container for ${BLUE_NAME}"
echo "OK: CODE_DEPLOY service started blue task ${BLUE_NAME}"

write_revision() {
	local dest="$1" td="$2"
	python3 - "$dest" "$td" <<'PY'
import json, sys
dest, td = sys.argv[1:]
content = {
    "version": 0.0,
    "Resources": [{
        "TargetService": {
            "Type": "AWS::ECS::Service",
            "Properties": {
                "TaskDefinition": td,
                "LoadBalancerInfo": {"ContainerName": "web", "ContainerPort": 80},
            },
        }
    }],
}
doc = {
    "revisionType": "AppSpecContent",
    "appSpecContent": {"content": json.dumps(content)},
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

MISSING_TD="arn:aws:ecs:${REGION}:000000000000:task-definition/no-such-${TS}:1"
write_revision "$TMPDIR/bad.json" "$MISSING_TD"
BAD_ID="$(aws deploy create-deployment --application-name "$APP" --deployment-group-name "$DG" \
	--revision "file://${TMPDIR}/bad.json" --query 'deploymentId' --output text)"
BAD_STATUS="$(aws deploy get-deployment --deployment-id "$BAD_ID" --query 'deploymentInfo.status' --output text)"
[[ "$BAD_STATUS" == "Failed" ]] || fail "bad deployment status is ${BAD_STATUS}"
STILL="$(aws elbv2 describe-listeners --listener-arns "$LIS_BG" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"
[[ "$STILL" == "$TG_BLUE" ]] || fail "failed deployment moved the listener to ${STILL}"
[[ "$(health_n "$TG_BLUE")" == "1" ]] || fail "failed deployment disturbed the blue target"
echo "OK: bad revision Failed, listener unchanged"

echo "==> CodeDeploy blue/green"
write_revision "$TMPDIR/good.json" "$TD_BG2"
GOOD_ID="$(aws deploy create-deployment --application-name "$APP" --deployment-group-name "$DG" \
	--revision "file://${TMPDIR}/good.json" --query 'deploymentId' --output text)"
GOOD_STATUS="$(aws deploy get-deployment --deployment-id "$GOOD_ID" --query 'deploymentInfo.status' --output text)"
[[ "$GOOD_STATUS" == "Succeeded" ]] || fail "deployment status is ${GOOD_STATUS}"
NOW="$(aws elbv2 describe-listeners --listener-arns "$LIS_BG" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"
[[ "$NOW" == "$TG_GREEN" ]] || fail "listener target group is ${NOW}, want green"
BLUE_N="$(aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" --query 'length(TargetHealthDescriptions)' --output text)"
[[ "$BLUE_N" == "0" ]] || fail "blue target group still has ${BLUE_N} targets"
wait_healthy "$TG_GREEN" 1
GREEN_PORT="$(tg_ports "$TG_GREEN" | awk '{print $1}')"
GREEN_NAMES="$(nlb_names "$BG_PORT")"
[[ "$(echo "$GREEN_NAMES" | grep -c '^v2-')" -eq 12 ]] || fail "listener is not serving v2 (${GREEN_NAMES})"
[[ -z "$(docker ps -q --filter "id=${BLUE_CID}")" ]] || fail "blue container ${BLUE_NAME} still running"
echo "OK: listener swapped to green"

echo "==> replace the green task"
GREEN_NAME="$(echo "$GREEN_NAMES" | head -1 | sed 's/^v2-//')"
GCID="$(cid_for_name "$GREEN_NAME")" || fail "no container for ${GREEN_NAME}"
GPORT="$(host_port_of "$GCID")"
docker kill "$GCID" >/dev/null
GREEN_REPLACED=0
NEW_PORT=""
for _ in $(seq 1 40); do
	HN="$(health_n "$TG_GREEN")"
	echo "health green healthy=${HN}"
	NEW_PORT="$(tg_ports "$TG_GREEN" | awk '{print $1}')"
	STILL_GREEN="$(aws elbv2 describe-listeners --listener-arns "$LIS_BG" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"
	if [[ "$HN" == "1" && -n "$NEW_PORT" && "$NEW_PORT" != "$GPORT" && "$STILL_GREEN" == "$TG_GREEN" ]]; then
		NEW_NAMES="$(nlb_names "$BG_PORT" || true)"
		if ! echo "$NEW_NAMES" | grep -qx "v2-${GREEN_NAME}"; then
			GREEN_REPLACED=1
			break
		fi
	fi
	sleep 2
done
[[ "$GREEN_REPLACED" == "1" ]] || fail "green task was not replaced (port ${NEW_PORT:-} was ${GPORT})"
echo "OK: green task replaced on ${NEW_PORT} (was ${GREEN_PORT})"
echo "OK: ecs-ec2 (cluster=${CLUSTER})"
