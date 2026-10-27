#!/usr/bin/env bash
# Seed the classic AWS three-tier HA diagram for the Architecture map (#389):
#   Users → Route 53 → (CloudFront gap) → S3 static
#                    ↘ ALB → ASG web (2 AZ) → ALB → ASG app (2 AZ) → RDS Multi-AZ
# LocalEmu + SeaweedFS only — never real AWS.
# CloudFront is not in LocalEmu SERVICES; classic ELB is disabled — we use elbv2 ALBs.
# See docs/architecture-map-org.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
S3EP="${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
REGION="${AWSBOX_REGION:-us-east-1}"
TAG_SCOPE="awsbox:architecture-map"
NAME_PREFIX="classic-3tier"
ZONE_NAME="${AWSBOX_CLASSIC_ZONE:-classic-3tier.awsbox.test}"
AMI="${AWSBOX_CLASSIC_AMI:-ami-localemu}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

aws_s3() {
	command aws --endpoint-url "$S3EP" "$@"
}

echo "seeding classic three-tier HA diagram on ${EP} …"
echo "  note: CloudFront not enabled in LocalEmu — R53 aliases web ALB; S3 is separate (honest gap)"

# --- VPC 10.0.0.0/16 (matches the public diagram CIDR) ---
VPC="$(aws ec2 describe-vpcs \
	--filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" \
	--query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
if [[ -z "$VPC" || "$VPC" == "None" ]]; then
	VPC="$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
		--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME_PREFIX}-vpc},{Key=${TAG_SCOPE},Value=1},{Key=awsbox:diagram,Value=classic-3tier}]" \
		--query 'Vpc.VpcId' --output text)"
	echo "  vpc $VPC"
else
	echo "  vpc $VPC (exists)"
fi

ensure_subnet() {
	local cidr="$1" az="$2" name="$3" map_public="$4" tier="$5"
	local id
	id="$(aws ec2 describe-subnets \
		--filters "Name=vpc-id,Values=${VPC}" "Name=tag:Name,Values=${name}" \
		--query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
	if [[ -z "$id" || "$id" == "None" ]]; then
		id="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$cidr" \
			--availability-zone "$az" \
			--tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=${TAG_SCOPE},Value=1},{Key=awsbox:tier,Value=${tier}}]" \
			--query 'Subnet.SubnetId' --output text)"
		if [[ "$map_public" == "1" ]]; then
			aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch >/dev/null || true
		fi
		echo "  subnet $id $name" >&2
	else
		echo "  subnet $id $name (exists)" >&2
	fi
	printf '%s\n' "$id"
}

# Diagram Subnet 1/2/3 — one /24 per AZ (honest; diagram draws a band spanning AZs)
WEB_A="$(ensure_subnet 10.0.0.0/24 "${REGION}a" "${NAME_PREFIX}-web-a" 1 web)"
WEB_B="$(ensure_subnet 10.0.10.0/24 "${REGION}b" "${NAME_PREFIX}-web-b" 1 web)"
APP_A="$(ensure_subnet 10.0.1.0/24 "${REGION}a" "${NAME_PREFIX}-app-a" 0 app)"
APP_B="$(ensure_subnet 10.0.11.0/24 "${REGION}b" "${NAME_PREFIX}-app-b" 0 app)"
DATA_A="$(ensure_subnet 10.0.2.0/24 "${REGION}a" "${NAME_PREFIX}-data-a" 0 data)"
DATA_B="$(ensure_subnet 10.0.12.0/24 "${REGION}b" "${NAME_PREFIX}-data-b" 0 data)"

# --- IGW ---
IGW="$(aws ec2 describe-internet-gateways \
	--filters "Name=attachment.vpc-id,Values=${VPC}" \
	--query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)"
if [[ -z "$IGW" || "$IGW" == "None" ]]; then
	IGW="$(aws ec2 create-internet-gateway \
		--tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME_PREFIX}-igw},{Key=${TAG_SCOPE},Value=1}]" \
		--query 'InternetGateway.InternetGatewayId' --output text)"
	aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" >/dev/null
	echo "  igw $IGW"
else
	echo "  igw $IGW (exists)"
fi

RTB="$(aws ec2 describe-route-tables \
	--filters "Name=vpc-id,Values=${VPC}" "Name=association.main,Values=true" \
	--query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
if [[ -n "$RTB" && "$RTB" != "None" ]]; then
	aws ec2 create-route --route-table-id "$RTB" --destination-cidr-block 0.0.0.0/0 \
		--gateway-id "$IGW" >/dev/null 2>&1 || true
	echo "  route 0.0.0.0/0 → $IGW"
fi

ensure_sg() {
	local name="$1" desc="$2"
	local id
	id="$(aws ec2 describe-security-groups \
		--filters "Name=vpc-id,Values=${VPC}" "Name=group-name,Values=${name}" \
		--query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
	if [[ -z "$id" || "$id" == "None" ]]; then
		id="$(aws ec2 create-security-group --vpc-id "$VPC" --group-name "$name" \
			--description "$desc" \
			--tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=${TAG_SCOPE},Value=1}]" \
			--query 'GroupId' --output text)"
		echo "  sg $id $name" >&2
	else
		echo "  sg $id $name (exists)" >&2
	fi
	printf '%s\n' "$id"
}

SG_WEB_ALB="$(ensure_sg "${NAME_PREFIX}-web-alb" "Classic diagram web ALB")"
SG_WEB="$(ensure_sg "${NAME_PREFIX}-web" "Classic diagram web ASG")"
SG_APP_ALB="$(ensure_sg "${NAME_PREFIX}-app-alb" "Classic diagram app ALB")"
SG_APP="$(ensure_sg "${NAME_PREFIX}-app" "Classic diagram app ASG")"
SG_DB="$(ensure_sg "${NAME_PREFIX}-db" "Classic diagram RDS")"

aws ec2 authorize-security-group-ingress --group-id "$SG_WEB_ALB" --protocol tcp --port 80 \
	--cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" --protocol tcp --port 80 \
	--source-group "$SG_WEB_ALB" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_APP_ALB" --protocol tcp --port 80 \
	--source-group "$SG_WEB" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 80 \
	--source-group "$SG_APP_ALB" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_DB" --protocol tcp --port 5432 \
	--source-group "$SG_APP" >/dev/null 2>&1 || true
echo "  sg ingress (users→web-alb→web→app-alb→app→db)"

# --- S3 static (diagram “Resources and Static Content”) ---
BUCKET="${NAME_PREFIX}-static"
if ! aws_s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
	aws_s3 s3api create-bucket --bucket "$BUCKET" >/dev/null
	echo "  s3 s3://${BUCKET}"
else
	echo "  s3 s3://${BUCKET} (exists)"
fi
echo '<html><body>classic-3tier static</body></html>' | aws_s3 s3 cp - "s3://${BUCKET}/index.html" >/dev/null
echo "  s3 object s3://${BUCKET}/index.html"

# --- Web ALB (diagram ELB #4) ---
ensure_alb() {
	local name="$1" scheme="$2" sub_a="$3" sub_b="$4" sg="$5"
	local arn
	arn="$(aws elbv2 describe-load-balancers --names "$name" \
		--query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
	if [[ -z "$arn" || "$arn" == "None" ]]; then
		arn="$(aws elbv2 create-load-balancer --name "$name" --type application \
			--scheme "$scheme" --subnets "$sub_a" "$sub_b" --security-groups "$sg" \
			--tags "Key=Name,Value=${name}" "Key=${TAG_SCOPE},Value=1" "Key=awsbox:diagram,Value=classic-3tier" \
			--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
		echo "  alb $name $arn ($scheme)" >&2
	else
		echo "  alb $name $arn (exists)" >&2
	fi
	printf '%s\n' "$arn"
}

WEB_ALB="$(ensure_alb "${NAME_PREFIX}-web-alb" internet-facing "$WEB_A" "$WEB_B" "$SG_WEB_ALB")"
APP_ALB="$(ensure_alb "${NAME_PREFIX}-app-alb" internal "$APP_A" "$APP_B" "$SG_APP_ALB")"

ensure_tg() {
	local name="$1"
	local arn
	arn="$(aws elbv2 describe-target-groups --names "$name" \
		--query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
	if [[ -z "$arn" || "$arn" == "None" ]]; then
		arn="$(aws elbv2 create-target-group --name "$name" \
			--protocol HTTP --port 80 --vpc-id "$VPC" --target-type instance \
			--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${name}" \
			--query 'TargetGroups[0].TargetGroupArn' --output text)"
		echo "  tg $name $arn" >&2
	else
		echo "  tg $name $arn (exists)" >&2
	fi
	printf '%s\n' "$arn"
}

WEB_TG="$(ensure_tg "${NAME_PREFIX}-web-tg")"
APP_TG="$(ensure_tg "${NAME_PREFIX}-app-tg")"

ensure_listener() {
	local lb_arn="$1" tg_arn="$2" label="$3"
	local lis
	lis="$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" \
		--query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
	if [[ -z "$lis" || "$lis" == "None" ]]; then
		aws elbv2 create-listener --load-balancer-arn "$lb_arn" --protocol HTTP --port 80 \
			--default-actions "Type=forward,TargetGroupArn=${tg_arn}" >/dev/null
		echo "  listener $label → tg"
	fi
}
ensure_listener "$WEB_ALB" "$WEB_TG" "web-alb"
ensure_listener "$APP_ALB" "$APP_TG" "app-alb"

# --- Launch templates + ASGs (diagram #5 web / app tiers) ---
ensure_lt() {
	local name="$1" role="$2" sg="$3"
	if aws ec2 describe-launch-templates --launch-template-names "$name" >/dev/null 2>&1; then
		echo "  lt $name (exists)" >&2
		return 0
	fi
	# shellcheck disable=SC2016
	aws ec2 create-launch-template --launch-template-name "$name" \
		--launch-template-data "{\"ImageId\":\"${AMI}\",\"InstanceType\":\"t3.micro\",\"SecurityGroupIds\":[\"${sg}\"],\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"${name}\"},{\"Key\":\"${TAG_SCOPE}\",\"Value\":\"1\"},{\"Key\":\"awsbox:role\",\"Value\":\"${role}\"},{\"Key\":\"awsbox:diagram\",\"Value\":\"classic-3tier\"}]}]}" \
		>/dev/null
	echo "  lt $name" >&2
}
ensure_lt "${NAME_PREFIX}-web-lt" web "$SG_WEB"
ensure_lt "${NAME_PREFIX}-app-lt" app "$SG_APP"

ensure_asg() {
	local name="$1" lt="$2" sub_a="$3" sub_b="$4" tg="$5"
	local existing
	existing="$(aws autoscaling describe-auto-scaling-groups \
		--auto-scaling-group-names "$name" \
		--query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null || true)"
	if [[ -z "$existing" || "$existing" == "None" ]]; then
		aws autoscaling create-auto-scaling-group \
			--auto-scaling-group-name "$name" \
			--launch-template "LaunchTemplateName=${lt},Version=\$Latest" \
			--min-size 2 --max-size 4 --desired-capacity 2 \
			--vpc-zone-identifier "${sub_a},${sub_b}" \
			--target-group-arns "$tg" \
			--tags "ResourceId=${name},ResourceType=auto-scaling-group,Key=Name,Value=${name},PropagateAtLaunch=true" \
			"ResourceId=${name},ResourceType=auto-scaling-group,Key=${TAG_SCOPE},Value=1,PropagateAtLaunch=true" \
			"ResourceId=${name},ResourceType=auto-scaling-group,Key=awsbox:diagram,Value=classic-3tier,PropagateAtLaunch=true" \
			>/dev/null
		echo "  asg $name desired=2" >&2
	else
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$name" \
			--desired-capacity 2 --min-size 2 --max-size 4 >/dev/null 2>&1 || true
		aws autoscaling attach-load-balancer-target-groups \
			--auto-scaling-group-name "$name" \
			--target-group-arns "$tg" >/dev/null 2>&1 || true
		echo "  asg $name (exists, desired=2)" >&2
	fi
}
ensure_asg "${NAME_PREFIX}-web-asg" "${NAME_PREFIX}-web-lt" "$WEB_A" "$WEB_B" "$WEB_TG"
ensure_asg "${NAME_PREFIX}-app-asg" "${NAME_PREFIX}-app-lt" "$APP_A" "$APP_B" "$APP_TG"

# Wait briefly for ASG instances so TG registration / map EC2 nodes appear
echo "  waiting for ASG instances …"
for _ in $(seq 1 20); do
	WEB_N="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${NAME_PREFIX}-web-asg" \
		--query 'length(AutoScalingGroups[0].Instances)' --output text 2>/dev/null || echo 0)"
	APP_N="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${NAME_PREFIX}-app-asg" \
		--query 'length(AutoScalingGroups[0].Instances)' --output text 2>/dev/null || echo 0)"
	[[ "${WEB_N:-0}" -ge 2 && "${APP_N:-0}" -ge 2 ]] && break
	sleep 2
done
echo "  asg instances web=${WEB_N:-?} app=${APP_N:-?}"

# LocalEmu ASG→TG attach often does not populate TargetHealth — register explicitly
# so the map can prove ALB → EC2 edges.
register_asg_targets() {
	local asg_name="$1" tg_arn="$2"
	local ids
	ids="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg_name" \
		--query 'AutoScalingGroups[0].Instances[].InstanceId' --output text 2>/dev/null || true)"
	[[ -z "$ids" || "$ids" == "None" ]] && return 0
	local args=()
	local id
	for id in $ids; do
		args+=("Id=${id}")
	done
	aws elbv2 register-targets --target-group-arn "$tg_arn" --targets "${args[@]}" >/dev/null 2>&1 || true
	echo "  registered ${#args[@]} targets on ${asg_name} → tg"
}
register_asg_targets "${NAME_PREFIX}-web-asg" "$WEB_TG"
register_asg_targets "${NAME_PREFIX}-app-asg" "$APP_TG"

# --- RDS Multi-AZ (diagram #7 + standby) ---
SNG="${NAME_PREFIX}-db-subnets"
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$SNG" >/dev/null 2>&1; then
	aws rds create-db-subnet-group --db-subnet-group-name "$SNG" \
		--db-subnet-group-description "Classic 3-tier data tier" \
		--subnet-ids "$DATA_A" "$DATA_B" \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${SNG}" >/dev/null 2>&1 || true
	echo "  db subnet group $SNG"
else
	echo "  db subnet group $SNG (exists)"
fi

DB_ID="${NAME_PREFIX}-db"
DB_STATE="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
	--query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"
if [[ -z "$DB_STATE" || "$DB_STATE" == "None" ]]; then
	aws rds create-db-instance \
		--db-instance-identifier "$DB_ID" \
		--db-instance-class db.t3.micro \
		--engine postgres \
		--engine-version 16.3 \
		--master-username awsbox \
		--master-user-password 'AwsboxClassic1!' \
		--allocated-storage 20 \
		--db-name classic \
		--db-subnet-group-name "$SNG" \
		--vpc-security-group-ids "$SG_DB" \
		--multi-az \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${DB_ID}" "Key=awsbox:diagram,Value=classic-3tier" \
		>/dev/null 2>&1 || \
	aws rds create-db-instance \
		--db-instance-identifier "$DB_ID" \
		--db-instance-class db.t3.micro \
		--engine postgres \
		--master-username awsbox \
		--master-user-password 'AwsboxClassic1!' \
		--allocated-storage 20 \
		--multi-az \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${DB_ID}" \
		>/dev/null 2>&1 || true
	echo "  rds $DB_ID Multi-AZ (creating)"
else
	echo "  rds $DB_ID ($DB_STATE)"
fi

# --- Route 53 public zone + alias to web ALB (diagram #1; CF #2 skipped) ---
ZONE_ID=""
EXISTING_ZONE="$(aws route53 list-hosted-zones \
	--query "HostedZones[?Name==\`${ZONE_NAME}.\` || Name==\`${ZONE_NAME}\`].Id" \
	--output text 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$EXISTING_ZONE" && "$EXISTING_ZONE" != "None" ]]; then
	ZONE_ID="${EXISTING_ZONE#/hostedzone/}"
	echo "  r53 zone $ZONE_NAME ($ZONE_ID exists)"
else
	ZONE_ID="$(aws route53 create-hosted-zone --name "$ZONE_NAME" \
		--caller-reference "classic-3tier-$(date +%s)" \
		--hosted-zone-config Comment="classic-3tier architecture-map seed" \
		--query 'HostedZone.Id' --output text)"
	ZONE_ID="${ZONE_ID#/hostedzone/}"
	echo "  r53 zone $ZONE_NAME ($ZONE_ID)"
fi

WEB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$WEB_ALB" \
	--query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
WEB_ZONE="$(aws elbv2 describe-load-balancers --load-balancer-arns "$WEB_ALB" \
	--query 'LoadBalancers[0].CanonicalHostedZoneId' --output text 2>/dev/null || true)"

if [[ -n "$ZONE_ID" && -n "$WEB_DNS" && "$WEB_DNS" != "None" ]]; then
	# Prefer ALB alias when LocalEmu returns a hosted zone id; else A record stub.
	if [[ -n "$WEB_ZONE" && "$WEB_ZONE" != "None" ]]; then
		aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
			--change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"www.${ZONE_NAME}\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${WEB_ZONE}\",\"DNSName\":\"${WEB_DNS}\",\"EvaluateTargetHealth\":false}}}]}" \
			>/dev/null 2>&1 || \
		aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
			--change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"www.${ZONE_NAME}\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${WEB_DNS}\"}]}}]}" \
			>/dev/null 2>&1 || true
	else
		aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
			--change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"www.${ZONE_NAME}\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${WEB_DNS}\"}]}}]}" \
			>/dev/null 2>&1 || true
	fi
	# Static content hostname → S3 website-style CNAME (no CloudFront)
	aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
		--change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"static.${ZONE_NAME}\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${BUCKET}.s3.amazonaws.com\"}]}}]}" \
		>/dev/null 2>&1 || true
	echo "  r53 www.${ZONE_NAME} → ${WEB_DNS}"
	echo "  r53 static.${ZONE_NAME} → ${BUCKET}.s3.amazonaws.com (no CloudFront)"
fi

# App role with intentional surprise Allow (honesty)
ROLE="${NAME_PREFIX}-app-role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
	aws iam create-role --role-name "$ROLE" \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${ROLE}" >/dev/null
	echo "  iam role $ROLE"
else
	echo "  iam role $ROLE (exists)"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name classic-app \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"Db","Effect":"Allow","Action":["rds:DescribeDBInstances","rds-db:connect"],"Resource":"*"},{"Sid":"SurpriseS3","Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":"*"}]}' \
	>/dev/null
echo "  iam role policy classic-app (rds + surprise s3)"

: "$DATA_A" "$DATA_B"

cat <<EOF

Classic three-tier seed ready.
  VPC=$VPC  zone=${ZONE_NAME}  web-alb=$WEB_ALB
  Gaps (honest): CloudFront not in SERVICES; classic ELB disabled (used ALB).
  Open console → Architecture → Architecture map
  Docs: docs/architecture-map-org.md
EOF
