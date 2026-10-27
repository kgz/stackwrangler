#!/usr/bin/env bash
# Apply examples/terraform/ecs-nginx, run-task (awsvpc), curl nginx.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/terraform/ecs-nginx"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
CLUSTER="awsbox-ecs-$(date +%s)"
FAMILY="awsbox-nginx-$(date +%s)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

cd "$EX"
# Unique VPC CIDR so localemu-vpc bridges do not exhaust Docker IPAM (#271).
VPC_CIDR="10.$((50 + RANDOM % 200)).0.0/16"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="cluster_name=${CLUSTER}" \
	-var="family=${FAMILY}" \
	-var="vpc_cidr=${VPC_CIDR}"

SUBNET="$(terraform output -raw subnet_id)"
SG="$(terraform output -raw security_group_id)"
NET="awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SG}],assignPublicIp=ENABLED}"

TASK_ARN="$(
	aws --endpoint-url "$EP" ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "$NET" \
		--query 'tasks[0].taskArn' --output text
)"
echo "TASK_ARN=${TASK_ARN}"

parse_task() {
	aws --endpoint-url "$EP" ecs describe-tasks \
		--cluster "$CLUSTER" --tasks "$TASK_ARN" --output json \
		| python3 -c '
import json, sys, re, subprocess
t = json.load(sys.stdin)["tasks"][0]
status = t.get("lastStatus") or ""
port = ""
for c in t.get("containers") or []:
    for b in c.get("networkBindings") or []:
        if b.get("hostPort"):
            port = str(b["hostPort"]); break
ip = ""
# Prefer the container Docker IP (#271): Describe attachments can show the
# AWS-side ENI address when the VPC bridge used a fallback CIDR (#268).
arn = t.get("taskArn") or ""
if arn:
    try:
        names = subprocess.check_output(
            ["docker", "ps", "--filter", f"label=localemu.task-arn={arn}",
             "--format", "{{.Names}}"],
            text=True,
        ).strip().splitlines()
        if names:
            dip = subprocess.check_output(
                ["docker", "inspect", "-f",
                 "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                 names[0]],
                text=True,
            ).strip()
            if dip:
                ip = dip
    except Exception:
        pass
if not ip:
    for a in t.get("attachments") or []:
        for d in a.get("details") or []:
            if d.get("name") == "privateIPv4Address" and d.get("value"):
                ip = d["value"]
    for c in t.get("containers") or []:
        for ni in c.get("networkInterfaces") or []:
            if ni.get("privateIpv4Address"):
                ip = ni["privateIpv4Address"]
if not port:
    try:
        out = subprocess.check_output(
            ["docker", "ps", "--filter", f"label=localemu.task-arn={arn}",
             "--format", "{{.Ports}}"],
            text=True,
        )
        m = re.search(r"0\.0\.0\.0:(\d+)->80", out) or re.search(r":(\d+)->80", out)
        if m:
            port = m.group(1)
    except Exception:
        pass
print(status)
print(port)
print(ip)
'
}

URL=""
for _ in $(seq 1 90); do
	mapfile -t info < <(parse_task)
	STATUS="${info[0]:-}"
	PORT="${info[1]:-}"
	TIP="${info[2]:-}"
	echo "status=${STATUS} port=${PORT} ip=${TIP}"

	if [[ "$STATUS" == "RUNNING" ]]; then
		# awsvpc (#271): no docker host publish — reach the task ENI IP first.
		if [[ -n "$TIP" ]] && curl -sf -m 5 "http://${TIP}/" >/tmp/awsbox-ecs-body 2>/dev/null; then
			URL="http://${TIP}/"
			break
		fi
		if [[ -n "$PORT" ]] && curl -sf -m 5 "http://127.0.0.1:${PORT}/" >/tmp/awsbox-ecs-body 2>/dev/null; then
			URL="http://127.0.0.1:${PORT}/"
			break
		fi
	fi
	if [[ "$STATUS" == "STOPPED" ]]; then
		aws --endpoint-url "$EP" ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" >&2
		echo "FAIL: task stopped before reachable" >&2
		exit 1
	fi
	sleep 2
done

if [[ -z "$URL" ]]; then
	echo "FAIL: no reachable URL (status=${STATUS:-?})" >&2
	exit 1
fi

BODY="$(curl -sS -m 15 "$URL")"
echo "$BODY" | head -3
echo "$BODY" | grep -qi 'html\|nginx\|welcome'
echo "OK: ecs nginx at ${URL} (cluster=${CLUSTER})"

aws --endpoint-url "$EP" ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
