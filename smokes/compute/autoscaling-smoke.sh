#!/usr/bin/env bash
# #83: Auto Scaling stub — create ASG, set desired capacity 2, describe shows 2.
# Real EC2 instance launch / ECS container instances: #207.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

TS="$(date +%s)"
ASG="awsbox-asg-${TS}"
LT="awsbox-asg-lt-${TS}"
KEEP="${AWSBOX_AUTOSCALING_KEEP:-0}"
VPC=""
SUB=""

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete >/dev/null 2>&1 || true
	aws ec2 delete-launch-template --launch-template-name "$LT" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

VPC="$(aws ec2 create-vpc --cidr-block 10.83.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.83.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"

aws ec2 create-launch-template --launch-template-name "$LT" \
	--launch-template-data '{"ImageId":"ami-localemu","InstanceType":"t3.micro"}' >/dev/null

aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG" \
	--launch-template "LaunchTemplateName=${LT},Version=\$Latest" \
	--min-size 0 --max-size 3 --desired-capacity 1 \
	--vpc-zone-identifier "$SUB"

aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 2

COUNT=""
DESIRED=""
for _ in $(seq 1 30); do
	read -r DESIRED COUNT <<<"$(
		aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
			--query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances)]' --output text
	)"
	[[ "$DESIRED" == "2" && "$COUNT" == "2" ]] && break
	sleep 2
done

[[ "$DESIRED" == "2" ]] || {
	echo "FAIL: DesiredCapacity=${DESIRED} want 2" >&2
	exit 1
}
[[ "$COUNT" == "2" ]] || {
	echo "FAIL: Instances=${COUNT} want 2 (describe-auto-scaling-groups)" >&2
	exit 1
}

echo "OK: autoscaling create/set-desired/describe (${ASG} desired=2 instances=2)"
