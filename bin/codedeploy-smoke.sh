#!/usr/bin/env bash
# #98: CodeDeploy application / deployment group smoke.
#   1) Lambda app + canary deployment group; create-deployment → Succeeded
#      (control plane only — alias traffic shift is Debt)
#   2) ECS blue/green (shares #207 runtime): missing task def → Failed;
#      good revision → Succeeded and listener forwards to the green TG
#
# Traffic goes through a 127.0.0.1 forwarder inside LocalEmu (same as #207).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
KEEP="${AWSBOX_CODEDEPLOY_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 180 "$@"
}

CLUSTER="awsbox-cd-${TS}"
BG_SVC="bg-${TS}"
BG_FAMILY="awsbox-cd-bg-${TS}"
ASG="cd-${TS}"
LT="cd-lt-${TS}"
APP_ECS="cd-ecs-${TS}"
DG_ECS="cd-ecs-${TS}"
APP_LAM="cd-lam-${TS}"
DG_LAM="cd-lam-${TS}"
ROLE="awsbox-cd-role-${TS}"
FN="awsbox-cd-fn-${TS}"
ALIAS="live"
BG_PORT=18091

VPC=""
SUB_A=""
SUB_B=""
IID=""
TG_BLUE=""
TG_GREEN=""
LB_BG=""
LIS_BG=""
LS=""
TMPDIR="${TMPDIR:-/tmp}/awsbox-codedeploy-$$"
mkdir -p "$TMPDIR"

fail() {
	echo "FAIL: $*" >&2
	aws deploy get-deployment --deployment-id "${GOOD_ID:-}" >&2 || true
	aws elbv2 describe-listeners --listener-arns "$LIS_BG" >&2 || true
	aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" >&2 || true
	aws elbv2 describe-target-health --target-group-arn "$TG_GREEN" >&2 || true
	exit 1
}

cleanup() {
	rm -rf "$TMPDIR"
	[[ "$KEEP" == "1" ]] && return 0
	aws ecs update-service --cluster "$CLUSTER" --service "$BG_SVC" --desired-count 0 >/dev/null 2>&1 || true
	aws ecs delete-service --cluster "$CLUSTER" --service "$BG_SVC" --force >/dev/null 2>&1 || true
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws deploy delete-deployment-group --application-name "$APP_ECS" --deployment-group-name "$DG_ECS" >/dev/null 2>&1 || true
	aws deploy delete-application --application-name "$APP_ECS" >/dev/null 2>&1 || true
	aws deploy delete-deployment-group --application-name "$APP_LAM" --deployment-group-name "$DG_LAM" >/dev/null 2>&1 || true
	aws deploy delete-application --application-name "$APP_LAM" >/dev/null 2>&1 || true
	aws lambda delete-alias --function-name "$FN" --name "$ALIAS" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	[[ -n "$LIS_BG" ]] && aws elbv2 delete-listener --listener-arn "$LIS_BG" >/dev/null 2>&1 || true
	[[ -n "$LB_BG" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB_BG" >/dev/null 2>&1 || true
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
[[ -n "$LS" ]] || fail "LocalEmu is not up (./bin/awsbox up)"

echo "==> Lambda CodeDeploy canary (control plane)"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

ZIP="$TMPDIR/fn.zip"
python3 - "$ZIP" <<'PY'
import sys, zipfile
code = b"exports.handler = async () => ({ ok: true });\n"
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY
LAM_ROLE="arn:aws:iam::000000000000:role/awsbox-lambda-basic"
aws iam get-role --role-name awsbox-lambda-basic >/dev/null 2>&1 || \
	aws iam create-role --role-name awsbox-lambda-basic \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws lambda create-function --function-name "$FN" --runtime nodejs18.x \
	--role "$LAM_ROLE" --handler index.handler --zip-file "fileb://${ZIP}" >/dev/null
for _ in $(seq 1 40); do
	st="$(aws lambda get-function --function-name "$FN" --query 'Configuration.State' --output text)"
	[[ "$st" == "Active" ]] && break
	sleep 1
done
aws lambda publish-version --function-name "$FN" >/dev/null
aws lambda create-alias --function-name "$FN" --name "$ALIAS" --function-version 1 >/dev/null

aws deploy create-application --application-name "$APP_LAM" --compute-platform Lambda >/dev/null
aws deploy create-deployment-group \
	--application-name "$APP_LAM" \
	--deployment-group-name "$DG_LAM" \
	--service-role-arn "$ROLE_ARN" \
	--deployment-config-name CodeDeployDefault.LambdaCanary10Percent5Minutes \
	--deployment-style deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL >/dev/null
CFG="$(aws deploy get-deployment-group --application-name "$APP_LAM" \
	--deployment-group-name "$DG_LAM" --query 'deploymentGroupInfo.deploymentConfigName' --output text)"
[[ "$CFG" == *LambdaCanary* ]] || fail "expected Lambda canary config, got ${CFG}"

python3 - "$TMPDIR/lam-rev.json" "$FN" "$ALIAS" <<'PY'
import json, sys
dest, fn, alias = sys.argv[1:]
content = {
    "version": 0.0,
    "Resources": [{
        "MyFunction": {
            "Type": "AWS::Lambda::Function",
            "Properties": {
                "Name": fn,
                "Alias": alias,
                "CurrentVersion": "1",
                "TargetVersion": "1",
            },
        }
    }],
}
doc = {"revisionType": "AppSpecContent", "appSpecContent": {"content": json.dumps(content)}}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
LAM_ID="$(aws deploy create-deployment --application-name "$APP_LAM" --deployment-group-name "$DG_LAM" \
	--revision "file://${TMPDIR}/lam-rev.json" --query 'deploymentId' --output text)"
LAM_STATUS="$(aws deploy get-deployment --deployment-id "$LAM_ID" --query 'deploymentInfo.status' --output text)"
[[ "$LAM_STATUS" == "Succeeded" ]] || fail "Lambda deployment status is ${LAM_STATUS}"
echo "OK: Lambda canary DG + deployment Succeeded (control plane)"

echo "==> ECS CodeDeploy blue/green setup"
# 10.218/16 avoids colliding with ecs-ec2-smoke (10.217) on a shared host.
VPC="$(aws ec2 create-vpc --cidr-block 10.218.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.218.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

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

mk_tg() {
	aws elbv2 create-target-group --name "$1" --protocol TCP --port 80 \
		--vpc-id "$VPC" --target-type instance \
		--health-check-protocol TCP --health-check-port traffic-port \
		--query 'TargetGroups[0].TargetGroupArn' --output text
}
TG_BLUE="$(mk_tg "cb${TS}")"
TG_GREEN="$(mk_tg "cg${TS}")"
LB_BG="$(aws elbv2 create-load-balancer --name "cdb${TS}" --type network --scheme internal \
	--subnets "$SUB_A" "$SUB_B" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LIS_BG="$(aws elbv2 create-listener --load-balancer-arn "$LB_BG" --protocol TCP --port "$BG_PORT" \
	--default-actions "Type=forward,TargetGroupArn=${TG_BLUE}" --query 'Listeners[0].ListenerArn' --output text)"

write_taskdef() {
	local family="$1" dest="$2" body="$3"
	python3 - "$family" "$dest" "$body" <<'PY'
import json, sys
family, dest, body = sys.argv[1:]
doc = {
    "family": family,
    "networkMode": "bridge",
    "requiresCompatibilities": ["EC2"],
    "containerDefinitions": [{
        "name": "web",
        "image": "nginx:1.27-alpine",
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
V2_CMD='echo -n "v2-$HOSTNAME" > /usr/share/nginx/html/index.html && exec nginx -g "daemon off;"'
write_taskdef "$BG_FAMILY" "$TMPDIR/bg.json" "$WEB_CMD"
write_taskdef "$BG_FAMILY" "$TMPDIR/bg2.json" "$V2_CMD"
TD_BG="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/bg.json" --query 'taskDefinition.taskDefinitionArn' --output text)"
TD_BG2="$(aws ecs register-task-definition --cli-input-json "file://${TMPDIR}/bg2.json" --query 'taskDefinition.taskDefinitionArn' --output text)"

aws deploy create-application --application-name "$APP_ECS" --compute-platform ECS >/dev/null
python3 - "$TMPDIR/dg.json" "$APP_ECS" "$DG_ECS" "$ROLE_ARN" "$CLUSTER" "$BG_SVC" "$LIS_BG" "cb${TS}" "cg${TS}" <<'PY'
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

health_n() {
	aws elbv2 describe-target-health --target-group-arn "$1" \
		--query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}
wait_healthy() {
	local arn="$1" want="$2" i n
	for i in $(seq 1 50); do
		n="$(health_n "$arn")"
		echo "health ${arn##*/} healthy=${n}"
		[[ "$n" == "$want" ]] && return 0
		sleep 2
	done
	fail "target group did not reach ${want} healthy"
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

wait_healthy "$TG_BLUE" 1
BLUE_NAME="$(nlb_names "$BG_PORT" | sort -u | head -1)"
[[ -n "$BLUE_NAME" && "$BLUE_NAME" != v2-* ]] || fail "blue NLB name is '${BLUE_NAME}'"
echo "OK: CODE_DEPLOY service blue task ${BLUE_NAME}"

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
doc = {"revisionType": "AppSpecContent", "appSpecContent": {"content": json.dumps(content)}}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

echo "==> sad: missing task definition"
MISSING_TD="arn:aws:ecs:${REGION}:000000000000:task-definition/no-such-${TS}:1"
write_revision "$TMPDIR/bad.json" "$MISSING_TD"
BAD_ID="$(aws deploy create-deployment --application-name "$APP_ECS" --deployment-group-name "$DG_ECS" \
	--revision "file://${TMPDIR}/bad.json" --query 'deploymentId' --output text)"
BAD_STATUS="$(aws deploy get-deployment --deployment-id "$BAD_ID" --query 'deploymentInfo.status' --output text)"
[[ "$BAD_STATUS" == "Failed" ]] || fail "bad deployment status is ${BAD_STATUS}"
STILL="$(aws elbv2 describe-listeners --listener-arns "$LIS_BG" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"
[[ "$STILL" == "$TG_BLUE" ]] || fail "failed deployment moved the listener to ${STILL}"
echo "OK: bad revision Failed, listener unchanged"

echo "==> happy: blue/green swap"
write_revision "$TMPDIR/good.json" "$TD_BG2"
GOOD_ID="$(aws deploy create-deployment --application-name "$APP_ECS" --deployment-group-name "$DG_ECS" \
	--revision "file://${TMPDIR}/good.json" --query 'deploymentId' --output text)"
GOOD_STATUS="$(aws deploy get-deployment --deployment-id "$GOOD_ID" --query 'deploymentInfo.status' --output text)"
[[ "$GOOD_STATUS" == "Succeeded" ]] || fail "deployment status is ${GOOD_STATUS}"
NOW="$(aws elbv2 describe-listeners --listener-arns "$LIS_BG" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"
[[ "$NOW" == "$TG_GREEN" ]] || fail "listener target group is ${NOW}, want green"
wait_healthy "$TG_GREEN" 1
GREEN_NAMES="$(nlb_names "$BG_PORT")"
[[ "$(echo "$GREEN_NAMES" | grep -c '^v2-')" -eq 12 ]] || fail "listener is not serving v2 (${GREEN_NAMES})"
echo "OK: listener swapped to green"
echo "OK: codedeploy (cluster=${CLUSTER})"
