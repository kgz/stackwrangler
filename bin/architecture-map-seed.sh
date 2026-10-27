#!/usr/bin/env bash
# Seed a one-account platform topology for the Architecture map (#389):
#   Internet → NLB/ALB → EC2 edge (Traefik/nginx stand-ins) → Lambda/S3
#   → ECS microservices → several RDS + SQS / IAM (with intentional surprise Allows).
# LocalEmu + SeaweedFS only — never real AWS.
# See docs/architecture-map-org.md (platform shape, not multi-tenant AWS sprawl).
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
NAME_PREFIX="arch-map"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

aws_s3() {
	command aws --endpoint-url "$S3EP" "$@"
}

echo "seeding Architecture map demo on ${EP} …"

# --- VPC (dedicated platform CIDR — do not reuse crm-platform 10.200.0.0/16) ---
VPC="$(aws ec2 describe-vpcs \
	--filters "Name=tag:Name,Values=${NAME_PREFIX}-vpc" \
	--query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
if [[ -z "$VPC" || "$VPC" == "None" ]]; then
	VPC="$(aws ec2 create-vpc --cidr-block 10.89.0.0/16 \
		--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME_PREFIX}-vpc},{Key=${TAG_SCOPE},Value=1},{Key=awsbox:tenant,Value=platform}]" \
		--query 'Vpc.VpcId' --output text)"
	echo "  vpc $VPC"
else
	echo "  vpc $VPC (exists)"
fi

ensure_subnet() {
	local cidr="$1" az="$2" name="$3" map_public="$4"
	local id
	id="$(aws ec2 describe-subnets \
		--filters "Name=vpc-id,Values=${VPC}" "Name=tag:Name,Values=${name}" \
		--query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
	if [[ -z "$id" || "$id" == "None" ]]; then
		id="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$cidr" \
			--availability-zone "$az" \
			--tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=${TAG_SCOPE},Value=1}]" \
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

PUB_A="$(ensure_subnet 10.89.1.0/24 "${REGION}a" "${NAME_PREFIX}-public-a" 1)"
PUB_B="$(ensure_subnet 10.89.2.0/24 "${REGION}b" "${NAME_PREFIX}-public-b" 1)"
PRIV_A="$(ensure_subnet 10.89.11.0/24 "${REGION}a" "${NAME_PREFIX}-private-app-a" 0)"
PRIV_B="$(ensure_subnet 10.89.12.0/24 "${REGION}b" "${NAME_PREFIX}-private-app-b" 0)"
DATA_A="$(ensure_subnet 10.89.21.0/24 "${REGION}a" "${NAME_PREFIX}-private-data-a" 0)"
DATA_B="$(ensure_subnet 10.89.22.0/24 "${REGION}b" "${NAME_PREFIX}-private-data-b" 0)"

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

# Default route → IGW (honest route edge on the map)
RTB="$(aws ec2 describe-route-tables \
	--filters "Name=vpc-id,Values=${VPC}" "Name=association.main,Values=true" \
	--query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
if [[ -n "$RTB" && "$RTB" != "None" ]]; then
	aws ec2 create-route --route-table-id "$RTB" --destination-cidr-block 0.0.0.0/0 \
		--gateway-id "$IGW" >/dev/null 2>&1 || true
	echo "  route 0.0.0.0/0 → $IGW on $RTB"
fi

# --- SG ---
SG="$(aws ec2 describe-security-groups \
	--filters "Name=vpc-id,Values=${VPC}" "Name=group-name,Values=${NAME_PREFIX}-alb" \
	--query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -z "$SG" || "$SG" == "None" ]]; then
	SG="$(aws ec2 create-security-group --vpc-id "$VPC" --group-name "${NAME_PREFIX}-alb" \
		--description "Architecture map ALB" \
		--tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME_PREFIX}-alb},{Key=${TAG_SCOPE},Value=1}]" \
		--query 'GroupId' --output text)"
	aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 80 \
		--cidr 0.0.0.0/0 >/dev/null 2>&1 || true
	echo "  sg $SG"
else
	echo "  sg $SG (exists)"
fi

# --- NAT (opt-in; Docker VPC NAT often SIGTERMs a busy LocalEmu under parallel smokes) ---
if [[ "${AWSBOX_ARCH_MAP_NAT:-0}" == "1" ]]; then
	seed_nat() {
		local subnet="$1" label="$2"
		local existing
		existing="$(aws ec2 describe-nat-gateways \
			--filter "Name=subnet-id,Values=${subnet}" "Name=state,Values=available,pending" \
			--query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || true)"
		if [[ -n "$existing" && "$existing" != "None" ]]; then
			echo "  nat $existing $label (exists)"
			return 0
		fi
		local alloc
		alloc="$(aws ec2 allocate-address --domain vpc \
			--tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME_PREFIX}-eip-${label}},{Key=${TAG_SCOPE},Value=1}]" \
			--query 'AllocationId' --output text 2>/dev/null || true)"
		if [[ -z "$alloc" || "$alloc" == "None" ]]; then
			echo "  nat $label skipped (no EIP)"
			return 0
		fi
		local nat
		nat="$(aws ec2 create-nat-gateway --subnet-id "$subnet" --allocation-id "$alloc" \
			--tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME_PREFIX}-nat-${label}},{Key=${TAG_SCOPE},Value=1}]" \
			--query 'NatGateway.NatGatewayId' --output text 2>/dev/null || true)"
		if [[ -n "$nat" && "$nat" != "None" ]]; then
			echo "  nat $nat $label"
		else
			echo "  nat $label skipped (create failed)"
		fi
	}
	seed_nat "$PUB_A" "az1"
	seed_nat "$PUB_B" "az2"
else
	echo "  nat skipped (set AWSBOX_ARCH_MAP_NAT=1 to create)"
fi

# --- ALB ---
ALB_ARN="$(aws elbv2 describe-load-balancers \
	--names "${NAME_PREFIX}-alb" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
	ALB_ARN="$(aws elbv2 create-load-balancer --name "${NAME_PREFIX}-alb" --type application \
		--scheme internet-facing --subnets "$PUB_A" "$PUB_B" --security-groups "$SG" \
		--tags "Key=Name,Value=${NAME_PREFIX}-alb" "Key=${TAG_SCOPE},Value=1" \
		--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
	echo "  alb $ALB_ARN"
else
	echo "  alb $ALB_ARN (exists)"
fi

# --- ECS ---
CLUSTER="${NAME_PREFIX}-app"
if ! aws ecs describe-clusters --clusters "$CLUSTER" \
	--query 'clusters[?status==`ACTIVE`].clusterName' --output text 2>/dev/null | grep -q "$CLUSTER"; then
	aws ecs create-cluster --cluster-name "$CLUSTER" \
		--tags "key=${TAG_SCOPE},value=1" "key=Name,value=${CLUSTER}" >/dev/null
	echo "  ecs cluster $CLUSTER"
else
	echo "  ecs cluster $CLUSTER (exists)"
fi

ROLE="${NAME_PREFIX}-task-role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
	aws iam create-role --role-name "$ROLE" \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${ROLE}" >/dev/null
	echo "  iam role $ROLE"
else
	echo "  iam role $ROLE (exists)"
fi

# Deliberately broad Allows — the map should surface these as extra access
# (happy-path diagrams often only draw "app → one queue").
aws iam put-role-policy --role-name "$ROLE" --policy-name arch-map-broad \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"IntendedQueue","Effect":"Allow","Action":["sqs:SendMessage","sqs:ReceiveMessage"],"Resource":"*"},{"Sid":"SurpriseS3","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket"],"Resource":"*"},{"Sid":"SurpriseRds","Effect":"Allow","Action":["rds:DescribeDBInstances","rds-db:connect"],"Resource":"*"}]}' \
	>/dev/null
echo "  iam role policy arch-map-broad (sqs + s3 + rds Allows — intentional surprise)"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

# --- SQS ---
QURL="$(aws sqs get-queue-url --queue-name "${NAME_PREFIX}-jobs" \
	--query QueueUrl --output text 2>/dev/null || true)"
if [[ -z "$QURL" || "$QURL" == "None" ]]; then
	QURL="$(aws sqs create-queue --queue-name "${NAME_PREFIX}-jobs" \
		--tags "${TAG_SCOPE}=1" \
		--query QueueUrl --output text)"
	echo "  sqs $QURL"
else
	echo "  sqs $QURL (exists)"
fi

# --- S3 static (SeaweedFS) ---
BUCKET="${NAME_PREFIX}-static"
if ! aws_s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
	aws_s3 s3api create-bucket --bucket "$BUCKET" >/dev/null
	echo "  s3 s3://${BUCKET}"
else
	echo "  s3 s3://${BUCKET} (exists)"
fi
echo '<html><body>arch-map</body></html>' | aws_s3 s3 cp - "s3://${BUCKET}/index.html" >/dev/null
echo "  s3 object s3://${BUCKET}/index.html"

# --- Target group + listener + task def + service (ALB→ECS + ECS→role edges) ---
TG_ARN="$(aws elbv2 describe-target-groups --names "${NAME_PREFIX}-tg" \
	--query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
	TG_ARN="$(aws elbv2 create-target-group --name "${NAME_PREFIX}-tg" \
		--protocol HTTP --port 80 --vpc-id "$VPC" --target-type ip \
		--tags "Key=${TAG_SCOPE},Value=1" \
		--query 'TargetGroups[0].TargetGroupArn' --output text)"
	echo "  tg $TG_ARN"
else
	echo "  tg $TG_ARN (exists)"
fi

# Associate TG with ALB via listener
LISTENER="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
	--query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
if [[ -z "$LISTENER" || "$LISTENER" == "None" ]]; then
	aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
		--default-actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
	echo "  listener HTTP:80 → tg"
fi

TASK_FAMILY="${NAME_PREFIX}-web"
TD_ARN="$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY" \
	--query 'taskDefinition.taskDefinitionArn' --output text 2>/dev/null || true)"
if [[ -z "$TD_ARN" || "$TD_ARN" == "None" ]]; then
	TD_ARN="$(aws ecs register-task-definition \
		--family "$TASK_FAMILY" \
		--requires-compatibilities FARGATE \
		--network-mode awsvpc \
		--cpu 256 --memory 512 \
		--task-role-arn "$ROLE_ARN" \
		--container-definitions '[{"name":"web","image":"public.ecr.aws/docker/library/nginx:alpine","essential":true,"portMappings":[{"containerPort":80,"protocol":"tcp"}]}]' \
		--query 'taskDefinition.taskDefinitionArn' --output text)"
	echo "  task def $TD_ARN"
else
	# Re-register so taskRoleArn stays current
	TD_ARN="$(aws ecs register-task-definition \
		--family "$TASK_FAMILY" \
		--requires-compatibilities FARGATE \
		--network-mode awsvpc \
		--cpu 256 --memory 512 \
		--task-role-arn "$ROLE_ARN" \
		--container-definitions '[{"name":"web","image":"public.ecr.aws/docker/library/nginx:alpine","essential":true,"portMappings":[{"containerPort":80,"protocol":"tcp"}]}]' \
		--query 'taskDefinition.taskDefinitionArn' --output text)"
	echo "  task def $TD_ARN (updated)"
fi

SVC="$(aws ecs describe-services --cluster "$CLUSTER" --services "${NAME_PREFIX}-svc" \
	--query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null || true)"
if [[ -z "$SVC" || "$SVC" == "None" ]]; then
	aws ecs create-service --cluster "$CLUSTER" --service-name "${NAME_PREFIX}-svc" \
		--task-definition "$TASK_FAMILY" --desired-count 0 --launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[${PRIV_A},${PRIV_B}],securityGroups=[${SG}],assignPublicIp=DISABLED}" \
		--load-balancers "targetGroupArn=${TG_ARN},containerName=web,containerPort=80" \
		>/dev/null 2>&1 || \
	aws ecs create-service --cluster "$CLUSTER" --service-name "${NAME_PREFIX}-svc" \
		--task-definition "$TASK_FAMILY" --desired-count 0 \
		--load-balancers "targetGroupArn=${TG_ARN},containerName=web,containerPort=80" \
		>/dev/null 2>&1 || true
	echo "  ecs service ${NAME_PREFIX}-svc (desired=0, LB wired)"
else
	echo "  ecs service $SVC (exists)"
fi

# --- NLB (edge front door) ---
NLB_ARN="$(aws elbv2 describe-load-balancers \
	--names "${NAME_PREFIX}-nlb" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [[ -z "$NLB_ARN" || "$NLB_ARN" == "None" ]]; then
	NLB_ARN="$(aws elbv2 create-load-balancer --name "${NAME_PREFIX}-nlb" --type network \
		--scheme internet-facing --subnets "$PUB_A" "$PUB_B" \
		--tags "Key=Name,Value=${NAME_PREFIX}-nlb" "Key=${TAG_SCOPE},Value=1" \
		--query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
	if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" ]]; then
		echo "  nlb $NLB_ARN"
	else
		echo "  nlb skipped (create failed)"
	fi
else
	echo "  nlb $NLB_ARN (exists)"
fi

NLB_TG="$(aws elbv2 describe-target-groups --names "${NAME_PREFIX}-nlb-tg" \
	--query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ -z "$NLB_TG" || "$NLB_TG" == "None" ]]; then
	NLB_TG="$(aws elbv2 create-target-group --name "${NAME_PREFIX}-nlb-tg" \
		--protocol TCP --port 443 --vpc-id "$VPC" --target-type instance \
		--tags "Key=${TAG_SCOPE},Value=1" \
		--query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
	echo "  nlb tg ${NLB_TG:-skipped}"
fi
if [[ -n "$NLB_ARN" && "$NLB_ARN" != "None" && -n "$NLB_TG" && "$NLB_TG" != "None" ]]; then
	NLB_LISTENER="$(aws elbv2 describe-listeners --load-balancer-arn "$NLB_ARN" \
		--query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)"
	if [[ -z "$NLB_LISTENER" || "$NLB_LISTENER" == "None" ]]; then
		aws elbv2 create-listener --load-balancer-arn "$NLB_ARN" --protocol TCP --port 443 \
			--default-actions "Type=forward,TargetGroupArn=${NLB_TG}" >/dev/null 2>&1 || true
		echo "  nlb listener TCP:443 → edge tg"
	fi
fi

# --- EC2 edge (Traefik / nginx stand-ins; Puppet-managed in the real org) ---
ensure_edge_instance() {
	local name="$1" role_label="$2"
	local existing
	existing="$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=${name}" "Name=instance-state-name,Values=pending,running,stopped" \
		--query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
	if [[ -n "$existing" && "$existing" != "None" ]]; then
		echo "  ec2 $existing $name (exists)"
		printf '%s\n' "$existing"
		return 0
	fi
	local iid
	iid="$(aws ec2 run-instances \
		--image-id ami-awsbox-edge \
		--instance-type t3.small \
		--subnet-id "$PUB_A" \
		--security-group-ids "$SG" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=${TAG_SCOPE},Value=1},{Key=awsbox:role,Value=${role_label}},{Key=awsbox:managed-by,Value=puppet}]" \
		--query 'Instances[0].InstanceId' --output text 2>/dev/null || true)"
	if [[ -n "$iid" && "$iid" != "None" ]]; then
		echo "  ec2 $iid $name ($role_label)"
		if [[ -n "$NLB_TG" && "$NLB_TG" != "None" ]]; then
			aws elbv2 register-targets --target-group-arn "$NLB_TG" \
				--targets "Id=${iid},Port=443" >/dev/null 2>&1 || true
		fi
		printf '%s\n' "$iid"
	else
		echo "  ec2 $name skipped (run-instances failed — LocalEmu may lack AMI)"
		printf '\n'
	fi
}

EDGE_TRAEFIK="$(ensure_edge_instance "${NAME_PREFIX}-edge-traefik" traefik)"
EDGE_NGINX="$(ensure_edge_instance "${NAME_PREFIX}-edge-nginx" nginx)"
: "$EDGE_TRAEFIK" "$EDGE_NGINX"

# --- Lambdas (webhooks / glue between edge and object store) ---
ensure_lambda() {
	local name="$1"
	if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
		echo "  lambda $name (exists)"
		return 0
	fi
	local zipdir zipp
	zipdir="$(mktemp -d)"
	printf 'exports.handler = async () => ({ statusCode: 200, body: "arch-map" });\n' \
		>"${zipdir}/index.js"
	zipp="${zipdir}/fn.zip"
	( cd "$zipdir" && zip -q "$zipp" index.js )
	aws lambda create-function --function-name "$name" \
		--runtime nodejs20.x --handler index.handler \
		--role "$ROLE_ARN" \
		--zip-file "fileb://${zipp}" \
		--tags "${TAG_SCOPE}=1" \
		>/dev/null 2>&1 || true
	rm -rf "$zipdir"
	echo "  lambda $name"
}
ensure_lambda "${NAME_PREFIX}-webhook"
ensure_lambda "${NAME_PREFIX}-ingest"

# Extra S3 artefact / upload buckets
for b in "${NAME_PREFIX}-uploads" "${NAME_PREFIX}-artefacts"; do
	if ! aws_s3 s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
		aws_s3 s3api create-bucket --bucket "$b" >/dev/null 2>&1 || true
		echo "  s3 s3://${b}"
	else
		echo "  s3 s3://${b} (exists)"
	fi
done

# --- More ECS microservices (talk to each other in the real org; control-plane here) ---
ensure_ecs_service() {
	local svc_name="$1" family="$2" image="$3"
	local td
	td="$(aws ecs register-task-definition \
		--family "$family" \
		--requires-compatibilities FARGATE \
		--network-mode awsvpc \
		--cpu 256 --memory 512 \
		--task-role-arn "$ROLE_ARN" \
		--container-definitions "[{\"name\":\"app\",\"image\":\"${image}\",\"essential\":true,\"portMappings\":[{\"containerPort\":8080,\"protocol\":\"tcp\"}]}]" \
		--query 'taskDefinition.taskDefinitionArn' --output text 2>/dev/null || true)"
	echo "  task def ${td:-$family}"
	local existing
	existing="$(aws ecs describe-services --cluster "$CLUSTER" --services "$svc_name" \
		--query 'services[?status==`ACTIVE`].serviceName' --output text 2>/dev/null || true)"
	if [[ -z "$existing" || "$existing" == "None" ]]; then
		aws ecs create-service --cluster "$CLUSTER" --service-name "$svc_name" \
			--task-definition "$family" --desired-count 0 --launch-type FARGATE \
			--network-configuration "awsvpcConfiguration={subnets=[${PRIV_A},${PRIV_B}],securityGroups=[${SG}],assignPublicIp=DISABLED}" \
			>/dev/null 2>&1 || true
		echo "  ecs service $svc_name (desired=0)"
	else
		echo "  ecs service $svc_name (exists)"
	fi
}
ensure_ecs_service "${NAME_PREFIX}-api" "${NAME_PREFIX}-api" "public.ecr.aws/docker/library/nginx:alpine"
ensure_ecs_service "${NAME_PREFIX}-worker" "${NAME_PREFIX}-worker" "public.ecr.aws/docker/library/nginx:alpine"
ensure_ecs_service "${NAME_PREFIX}-billing" "${NAME_PREFIX}-billing" "public.ecr.aws/docker/library/nginx:alpine"

# Orphan DLQ — honesty: queue with no consumer wiring
DLQ="$(aws sqs get-queue-url --queue-name "${NAME_PREFIX}-dlq" \
	--query QueueUrl --output text 2>/dev/null || true)"
if [[ -z "$DLQ" || "$DLQ" == "None" ]]; then
	DLQ="$(aws sqs create-queue --queue-name "${NAME_PREFIX}-dlq" \
		--tags "${TAG_SCOPE}=1" \
		--query QueueUrl --output text 2>/dev/null || true)"
	echo "  sqs dlq $DLQ (orphan — no consumer)"
else
	echo "  sqs dlq $DLQ (exists)"
fi

# --- Several RDS (create only; map does not need SQL ready) ---
ensure_rds() {
	local db_id="$1" db_name="$2"
	local state
	state="$(aws rds describe-db-instances --db-instance-identifier "$db_id" \
		--query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"
	if [[ -z "$state" || "$state" == "None" ]]; then
		aws rds create-db-instance \
			--db-instance-identifier "$db_id" \
			--db-instance-class db.t3.micro \
			--engine postgres \
			--engine-version 16.3 \
			--master-username awsbox \
			--master-user-password 'AwsboxArchMap1!' \
			--allocated-storage 20 \
			--db-name "$db_name" \
			--tags "Key=${TAG_SCOPE},Value=1" "Key=Name,Value=${db_id}" >/dev/null 2>&1 || true
		echo "  rds $db_id (creating)"
	else
		echo "  rds $db_id ($state)"
	fi
}
ensure_rds "${NAME_PREFIX}-db" archmap
ensure_rds "${NAME_PREFIX}-db-analytics" analytics
ensure_rds "${NAME_PREFIX}-db-shared" shared

# silence unused subnet vars for shellcheck (used as side-effect creates)
: "$PRIV_A" "$PRIV_B" "$DATA_A" "$DATA_B"

cat <<EOF

Architecture map platform seed ready (one account, multi-tier — not multi-tenant AWS).
  VPC=$VPC
  Open console → Architecture → Architecture map
  ./bin/awsbox console   → http://127.0.0.1:3000/architecture
  Docs: docs/architecture-map-org.md
EOF
