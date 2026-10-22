#!/usr/bin/env bash
# Create VPC/subnet/SG (and the other pinned types) with _custom_id_ and check
# describe output plus the account id in OwnerId / STS / ARNs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_CUSTOM_ID_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

VPC_ID="vpc-0123456789abcdef0"
SUBNET_ID="subnet-0123456789abcdef1"
SG_ID="sg-0123456789abcdef2"
RTB_ID="rtb-0123456789abcdef3"
IGW_ID="igw-0123456789abcdef4"
PCX_ID="pcx-0123456789abcdef5"
INSTANCE_ID="i-0123456789abcdef6"
LB_SUFFIX="0123456789abcdef"
TG_SUFFIX="fedcba9876543210"
REST_ID="abcde12345"
HTTP_ID="fghij67890"
ZONE_ID="ZCUSTOMID12345"

account_for_key() {
	local part key_part acct
	local map="${AWSBOX_ACCOUNT_IDS:-}"
	IFS=',' read -ra parts <<< "$map"
	for part in "${parts[@]}"; do
		part="${part// /}"
		key_part="${part%%=*}"
		acct="${part#*=}"
		if [[ -n "$key_part" && "$key_part" == "$KEY" && "$acct" != "$part" ]]; then
			echo "$acct"
			return
		fi
	done
	if [[ -n "${AWSBOX_ACCOUNT_ID:-}" ]]; then
		echo "$AWSBOX_ACCOUNT_ID"
		return
	fi
	echo "000000000000"
}

ACCOUNT="$(account_for_key)"
CLUSTER="c${TS}"
CLUSTER_ARN="arn:aws:ecs:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
LB_NAME="c214${TS}"
TG_NAME="t214${TS}"

VPC2=""
SUBNET2=""
LB_ARN=""
TG_ARN=""
IID=""
PCX=""
ZONE=""
REST=""
HTTP=""
KEEP="${AWSBOX_CUSTOM_ID_KEEP:-0}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

need() {
	local label="$1" got="$2" want="$3"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL ${label}: got '${got}' want '${want}'" >&2
		exit 1
	fi
	echo "ok ${label}=${got}"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	set +e
	[[ -n "$IID" ]] && aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1
	[[ -n "$PCX" ]] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null 2>&1
	[[ -n "$LB_ARN" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" >/dev/null 2>&1
	[[ -n "$TG_ARN" ]] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN" >/dev/null 2>&1
	[[ -n "$IGW_ID" ]] && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" >/dev/null 2>&1
	[[ -n "$SUBNET_ID" ]] && aws ec2 delete-subnet --subnet-id "$SUBNET_ID" >/dev/null 2>&1
	[[ -n "$SUBNET2" ]] && aws ec2 delete-subnet --subnet-id "$SUBNET2" >/dev/null 2>&1
	[[ -n "$SG_ID" ]] && aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1
	[[ -n "$RTB_ID" ]] && aws ec2 delete-route-table --route-table-id "$RTB_ID" >/dev/null 2>&1
	[[ -n "$VPC2" ]] && aws ec2 delete-vpc --vpc-id "$VPC2" >/dev/null 2>&1
	[[ -n "$VPC_ID" ]] && aws ec2 delete-vpc --vpc-id "$VPC_ID" >/dev/null 2>&1
	[[ -n "$ZONE" ]] && aws route53 delete-hosted-zone --id "$ZONE" >/dev/null 2>&1
	[[ -n "$REST" ]] && aws apigateway delete-rest-api --rest-api-id "$REST" >/dev/null 2>&1
	[[ -n "$HTTP" ]] && aws apigatewayv2 delete-api --api-id "$HTTP" >/dev/null 2>&1
	[[ -n "$CLUSTER" ]] && aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1
	return 0
}
trap cleanup EXIT

echo "endpoint=${EP} account=${ACCOUNT} key=${KEY}"

set +e
sad="$(aws ec2 create-vpc --cidr-block 10.9.0.0/16 \
	--tag-specifications 'ResourceType=vpc,Tags=[{Key=_custom_id_,Value=vpc-not-an-id}]' 2>&1)"
sad_rc=$?
set -e
[[ "$sad_rc" -ne 0 ]]
echo "$sad" | grep -q 'InvalidParameterValue'
echo "ok bad _custom_id_ rejected"

sts="$(aws sts get-caller-identity --query Account --output text)"
need "sts account" "$sts" "$ACCOUNT"

plain="$(aws ec2 create-vpc --cidr-block 10.6.0.0/16 --query 'Vpc.VpcId' --output text)"
[[ "$plain" =~ ^vpc-[0-9a-f]+$ ]]
[[ "$plain" != "$VPC_ID" ]]
aws ec2 delete-vpc --vpc-id "$plain" >/dev/null
echo "ok untagged vpc ${plain}"

vpc="$(aws ec2 create-vpc --cidr-block 10.7.0.0/16 \
	--tag-specifications "ResourceType=vpc,Tags=[{Key=_custom_id_,Value=${VPC_ID}}]" \
	--query 'Vpc.VpcId' --output text)"
need "create vpc" "$vpc" "$VPC_ID"
read -r described owner <<<"$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
	--query 'Vpcs[0].[VpcId,OwnerId]' --output text)"
need "describe vpc" "$described" "$VPC_ID"
need "vpc owner" "$owner" "$ACCOUNT"

subnet="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.7.1.0/24 \
	--tag-specifications "ResourceType=subnet,Tags=[{Key=_custom_id_,Value=${SUBNET_ID}}]" \
	--query 'Subnet.SubnetId' --output text)"
need "create subnet" "$subnet" "$SUBNET_ID"
read -r described owner <<<"$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
	--query 'Subnets[0].[SubnetId,OwnerId]' --output text)"
need "describe subnet" "$described" "$SUBNET_ID"
need "subnet owner" "$owner" "$ACCOUNT"

sg="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "cid-${TS}" \
	--description "custom id smoke" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=_custom_id_,Value=${SG_ID}}]" \
	--query 'GroupId' --output text)"
need "create sg" "$sg" "$SG_ID"
read -r described owner <<<"$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
	--query 'SecurityGroups[0].[GroupId,OwnerId]' --output text)"
need "describe sg" "$described" "$SG_ID"
need "sg owner" "$owner" "$ACCOUNT"

rtb="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
	--tag-specifications "ResourceType=route-table,Tags=[{Key=_custom_id_,Value=${RTB_ID}}]" \
	--query 'RouteTable.RouteTableId' --output text)"
need "create rtb" "$rtb" "$RTB_ID"
described="$(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
	--query 'RouteTables[0].RouteTableId' --output text)"
need "describe rtb" "$described" "$RTB_ID"

igw="$(aws ec2 create-internet-gateway \
	--tag-specifications "ResourceType=internet-gateway,Tags=[{Key=_custom_id_,Value=${IGW_ID}}]" \
	--query 'InternetGateway.InternetGatewayId' --output text)"
need "create igw" "$igw" "$IGW_ID"
described="$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
	--query 'InternetGateways[0].InternetGatewayId' --output text)"
need "describe igw" "$described" "$IGW_ID"

VPC2="$(aws ec2 create-vpc --cidr-block 10.8.0.0/16 --query 'Vpc.VpcId' --output text)"
PCX="$(aws ec2 create-vpc-peering-connection --vpc-id "$VPC_ID" --peer-vpc-id "$VPC2" \
	--tag-specifications "ResourceType=vpc-peering-connection,Tags=[{Key=_custom_id_,Value=${PCX_ID}}]" \
	--query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)"
need "create pcx" "$PCX" "$PCX_ID"
described="$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids "$PCX_ID" \
	--query 'VpcPeeringConnections[0].VpcPeeringConnectionId' --output text)"
need "describe pcx" "$described" "$PCX_ID"

IID="$(aws ec2 run-instances --image-id ami-12345678 --instance-type t3.micro --count 1 \
	--subnet-id "$SUBNET_ID" \
	--tag-specifications "ResourceType=instance,Tags=[{Key=_custom_id_,Value=${INSTANCE_ID}}]" \
	--query 'Instances[0].InstanceId' --output text)"
need "create instance" "$IID" "$INSTANCE_ID"
described="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
	--query 'Reservations[0].Instances[0].InstanceId' --output text)"
need "describe instance" "$described" "$INSTANCE_ID"

SUBNET2="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.7.2.0/24 \
	--query 'Subnet.SubnetId' --output text)"
LB_ARN="$(aws elbv2 create-load-balancer --name "$LB_NAME" --type network \
	--subnets "$SUBNET_ID" \
	--tags "Key=_custom_id_,Value=${LB_SUFFIX}" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
[[ "$LB_ARN" == *":${ACCOUNT}:"* ]]
[[ "$LB_ARN" == */"${LB_SUFFIX}" ]]
described="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
need "describe lb" "$described" "$LB_ARN"
echo "ok lb arn=${LB_ARN}"

TG_ARN="$(aws elbv2 create-target-group --name "$TG_NAME" --protocol TCP --port 80 \
	--vpc-id "$VPC_ID" --target-type instance \
	--tags "Key=_custom_id_,Value=${TG_SUFFIX}" \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
[[ "$TG_ARN" == *":${ACCOUNT}:"* ]]
[[ "$TG_ARN" == */"${TG_SUFFIX}" ]]
described="$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
need "describe tg" "$described" "$TG_ARN"
echo "ok tg arn=${TG_ARN}"

REST="$(aws apigateway create-rest-api --name "rest-${TS}" \
	--tags "_custom_id_=${REST_ID}" --query id --output text)"
need "create rest" "$REST" "$REST_ID"
described="$(aws apigateway get-rest-api --rest-api-id "$REST_ID" --query id --output text)"
need "get rest" "$described" "$REST_ID"

HTTP="$(aws apigatewayv2 create-api --name "http-${TS}" --protocol-type HTTP \
	--tags "_custom_id_=${HTTP_ID}" --query ApiId --output text)"
need "create http" "$HTTP" "$HTTP_ID"
described="$(aws apigatewayv2 get-api --api-id "$HTTP_ID" --query ApiId --output text)"
need "get http" "$described" "$HTTP_ID"

ZONE="$(aws route53 create-hosted-zone --name "cid-${TS}.example.com" \
	--caller-reference "${ZONE_CALLER:-_custom_id_:${ZONE_ID}}" \
	--query 'HostedZone.Id' --output text)"
[[ "$ZONE" == *"${ZONE_ID}" ]]
described="$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'HostedZone.Id' --output text)"
[[ "$described" == *"${ZONE_ID}" ]]
echo "ok hosted zone=${described}"

created="$(aws ecs create-cluster --cluster-name "$CLUSTER" \
	--tags "key=_custom_id_,value=${CLUSTER_ARN}" \
	--query 'cluster.clusterArn' --output text)"
need "create cluster" "$created" "$CLUSTER_ARN"
described="$(aws ecs describe-clusters --clusters "$CLUSTER" \
	--query 'clusters[0].clusterArn' --output text)"
need "describe cluster" "$described" "$CLUSTER_ARN"

echo "custom-id smoke ok"
