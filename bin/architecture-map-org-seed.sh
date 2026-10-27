#!/usr/bin/env bash
# UI stress seed — CRM t000N sprawl in one account (not a live topology).
# Prefer ./bin/architecture-map-seed.sh for realistic platform shape.
# Keep this script to thrash Architecture map density. See docs/architecture-map-org.md
#
# Does NOT run other smokes; safe to leave until LocalEmu is idle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
S3EP="${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
REGION="${AWSBOX_REGION:-us-east-1}"

TENANTS="${TENANTS:-12}"
STAFF_PER_TENANT="${STAFF_PER_TENANT:-8}"
BUCKETS_PER_TENANT="${BUCKETS_PER_TENANT:-8}"
LAMBDAS_PER_TENANT="${LAMBDAS_PER_TENANT:-2}"
AWSBOX_ORG_RDS="${AWSBOX_ORG_RDS:-0}"
RDS_TENANTS="${RDS_TENANTS:-2}"
START_INDEX="${START_INDEX:-1}"
DRY_RUN="${DRY_RUN:-0}"

TAG_SCOPE="awsbox:architecture-map"
PREFIX="crm"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" "$@"; }
aws_s3() { command aws --endpoint-url "$S3EP" "$@"; }

if ! [[ "$TENANTS" =~ ^[0-9]+$ ]] || [[ "$TENANTS" -lt 1 ]]; then
	echo "TENANTS must be a positive integer" >&2
	exit 1
fi

if [[ "$TENANTS" -gt 200 && "${AWSBOX_ORG_I_MEAN_IT:-0}" != "1" ]]; then
	echo "refusing TENANTS=${TENANTS} without AWSBOX_ORG_I_MEAN_IT=1 (LocalEmu/disk risk)" >&2
	exit 1
fi

slug_for() {
	# t0001 → tenant-0001 (stable, dns-ish)
	printf 'tenant-%04d' "$1"
}

echo "org-scale architecture seed"
echo "  tenants=${TENANTS} staff/tenant=${STAFF_PER_TENANT} buckets/tenant=${BUCKETS_PER_TENANT}"
echo "  lambdas/tenant=${LAMBDAS_PER_TENANT} rds=${AWSBOX_ORG_RDS} (first ${RDS_TENANTS})"
echo "  endpoint=${EP}"
if [[ "$DRY_RUN" == "1" ]]; then
	echo "  DRY_RUN=1 — printing plan only"
fi

# Shared trust docs
TASK_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# Minimal lambda zip (once)
ZIP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$ZIP_DIR"; }
trap cleanup EXIT
printf 'def handler(event, context):\n    return {"ok": True}\n' >"$ZIP_DIR/lambda_function.py"
( cd "$ZIP_DIR" && zip -q lambda.zip lambda_function.py )
LAMBDA_ZIP="$ZIP_DIR/lambda.zip"

ensure_role() {
	local name="$1" trust="$2"
	if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
		return 0
	fi
	aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=awsbox:tenant,Value=${TENANT_ID}" \
		"Key=awsbox:tenant-name,Value=${TENANT_SLUG}" "Key=Name,Value=${name}" >/dev/null
}

put_broad_s3_allow() {
	# Intentional surprise: identity Allow broader than the tenant diagram
	local role="$1"
	aws iam put-role-policy --role-name "$role" --policy-name broad-s3-all-tenants \
		--policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"SurpriseAllBuckets","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket","s3:DeleteObject"],"Resource":"*"},{"Sid":"IntendedQueue","Effect":"Allow","Action":["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage"],"Resource":"*"}]}' \
		>/dev/null
}

put_tight_queue_allow() {
	local role="$1" queue_arn_prefix="$2"
	aws iam put-role-policy --role-name "$role" --policy-name tenant-queues \
		--policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sqs:SendMessage\",\"sqs:ReceiveMessage\"],\"Resource\":\"${queue_arn_prefix}*\"}]}" \
		>/dev/null 2>&1 || true
}

create_queue() {
	local name="$1"
	local url
	url="$(aws sqs get-queue-url --queue-name "$name" --query QueueUrl --output text 2>/dev/null || true)"
	if [[ -z "$url" || "$url" == "None" ]]; then
		url="$(aws sqs create-queue --queue-name "$name" \
			--tags "${TAG_SCOPE}=1,awsbox:tenant=${TENANT_ID},awsbox:tenant-name=${TENANT_SLUG}" \
			--query QueueUrl --output text)"
	fi
	printf '%s' "$url"
}

create_bucket() {
	local name="$1"
	if ! aws_s3 s3api head-bucket --bucket "$name" >/dev/null 2>&1; then
		aws_s3 s3api create-bucket --bucket "$name" >/dev/null
	fi
	# Seaweed/Local often ignore bucket tagging via s3api; Name is in the bucket id
	echo "seed $(date -Iseconds)" | aws_s3 s3 cp - "s3://${name}/.awsbox-org-seed" >/dev/null 2>&1 || true
}

create_user() {
	local name="$1"
	if aws iam get-user --user-name "$name" >/dev/null 2>&1; then
		return 0
	fi
	aws iam create-user --user-name "$name" \
		--tags "Key=${TAG_SCOPE},Value=1" "Key=awsbox:tenant,Value=${TENANT_ID}" \
		"Key=awsbox:tenant-name,Value=${TENANT_SLUG}" "Key=Name,Value=${name}" >/dev/null
}

create_lambda() {
	local name="$1" role_arn="$2"
	if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
		return 0
	fi
	aws lambda create-function --function-name "$name" \
		--runtime python3.12 --role "$role_arn" --handler lambda_function.handler \
		--zip-file "fileb://${LAMBDA_ZIP}" \
		--tags "${TAG_SCOPE}=1,awsbox:tenant=${TENANT_ID},awsbox:tenant-name=${TENANT_SLUG}" \
		>/dev/null 2>&1 || \
	aws lambda create-function --function-name "$name" \
		--runtime python3.12 --role "$role_arn" --handler lambda_function.handler \
		--zip-file "fileb://${LAMBDA_ZIP}" \
		>/dev/null
}

END_INDEX=$((START_INDEX + TENANTS - 1))
CREATED=0

for ((i = START_INDEX; i <= END_INDEX; i++)); do
	TENANT_ID="$(printf 't%04d' "$i")"
	TENANT_SLUG="$(slug_for "$i")"
	echo "── ${TENANT_ID} (${TENANT_SLUG}) ──"

	if [[ "$DRY_RUN" == "1" ]]; then
		echo "  would create: ${STAFF_PER_TENANT} users, ${BUCKETS_PER_TENANT} buckets, 4 queues, ${LAMBDAS_PER_TENANT} lambdas, 4 roles"
		CREATED=$((CREATED + 1))
		continue
	fi

	# IAM group + staff sample
	GROUP="${PREFIX}-${TENANT_SLUG}-staff"
	aws iam create-group --group-name "$GROUP" >/dev/null 2>&1 || true
	for ((u = 1; u <= STAFF_PER_TENANT; u++)); do
		UNAME="${PREFIX}-${TENANT_SLUG}-user-$(printf '%03d' "$u")"
		create_user "$UNAME"
		aws iam add-user-to-group --group-name "$GROUP" --user-name "$UNAME" >/dev/null 2>&1 || true
	done
	echo "  staff users ${STAFF_PER_TENANT} in ${GROUP}"

	# Roles
	ROLE_API="${PREFIX}-${TENANT_SLUG}-api"
	ROLE_MOBILE="${PREFIX}-${TENANT_SLUG}-mobile"
	ROLE_LAMBDA="${PREFIX}-${TENANT_SLUG}-lambda"
	ROLE_BACKUP="${PREFIX}-${TENANT_SLUG}-backup"
	ensure_role "$ROLE_API" "$TASK_TRUST"
	ensure_role "$ROLE_MOBILE" "$TASK_TRUST"
	ensure_role "$ROLE_LAMBDA" "$LAMBDA_TRUST"
	ensure_role "$ROLE_BACKUP" "$TASK_TRUST"
	ROLE_API_ARN="$(aws iam get-role --role-name "$ROLE_API" --query Role.Arn --output text)"
	ROLE_LAMBDA_ARN="$(aws iam get-role --role-name "$ROLE_LAMBDA" --query Role.Arn --output text)"

	# Queues
	Q_EVENTS="$(create_queue "${PREFIX}-${TENANT_SLUG}-events")"
	Q_JOBS="$(create_queue "${PREFIX}-${TENANT_SLUG}-jobs")"
	Q_MOBILE="$(create_queue "${PREFIX}-${TENANT_SLUG}-mobile-push")"
	Q_DLQ="$(create_queue "${PREFIX}-${TENANT_SLUG}-dlq")"
	echo "  sqs events/jobs/mobile/dlq"

	# Buckets (CRM modules + backups)
	for ((b = 1; b <= BUCKETS_PER_TENANT; b++)); do
		# bucket names: lowercase, global-unique on Seaweed
		BNAME="${PREFIX}-${TENANT_SLUG}-b$(printf '%02d' "$b")"
		create_bucket "$BNAME"
	done
	create_bucket "${PREFIX}-${TENANT_SLUG}-backups"
	echo "  s3 ${BUCKETS_PER_TENANT} app + backups"

	# IAM policies — tight on mobile, broad surprise on api
	put_tight_queue_allow "$ROLE_MOBILE" "arn:aws:sqs:${REGION}:000000000000:${PREFIX}-${TENANT_SLUG}-"
	put_broad_s3_allow "$ROLE_API"
	put_broad_s3_allow "$ROLE_BACKUP"
	echo "  iam policies (api+backup = broad s3:* surprise)"

	# Lambdas
	for ((l = 1; l <= LAMBDAS_PER_TENANT; l++)); do
		LNAME="${PREFIX}-${TENANT_SLUG}-fn-$(printf '%02d' "$l")"
		create_lambda "$LNAME" "$ROLE_LAMBDA_ARN"
	done
	echo "  lambda × ${LAMBDAS_PER_TENANT}"

	# Optional RDS (heavy)
	if [[ "$AWSBOX_ORG_RDS" == "1" && "$i" -lt $((START_INDEX + RDS_TENANTS)) ]]; then
		DB_ID="${PREFIX}-${TENANT_SLUG}-db"
		if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
			aws rds create-db-instance \
				--db-instance-identifier "$DB_ID" \
				--db-instance-class db.t3.micro \
				--engine postgres --engine-version 16.3 \
				--master-username awsbox --master-user-password 'AwsboxOrgCrm1!' \
				--allocated-storage 20 --db-name crm \
				--tags "Key=${TAG_SCOPE},Value=1" "Key=awsbox:tenant,Value=${TENANT_ID}" \
				"Key=awsbox:tenant-name,Value=${TENANT_SLUG}" "Key=Name,Value=${DB_ID}" \
				>/dev/null
			echo "  rds ${DB_ID} (creating)"
		else
			echo "  rds ${DB_ID} (exists)"
		fi
	fi

	CREATED=$((CREATED + 1))
done

# Shared platform VPC marker (lightweight) so map has a networking home
if [[ "$DRY_RUN" != "1" ]]; then
	VPC="$(aws ec2 describe-vpcs --filters "Name=tag:${TAG_SCOPE},Values=1" "Name=tag:awsbox:tenant,Values=platform" \
		--query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
	if [[ -z "$VPC" || "$VPC" == "None" ]]; then
		VPC="$(aws ec2 create-vpc --cidr-block 10.200.0.0/16 \
			--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-platform-vpc},{Key=${TAG_SCOPE},Value=1},{Key=awsbox:tenant,Value=platform},{Key=awsbox:tenant-name,Value=platform}]" \
			--query Vpc.VpcId --output text 2>/dev/null || true)"
		echo "  platform vpc ${VPC:-skipped}"
	else
		echo "  platform vpc ${VPC} (exists)"
	fi
fi

cat <<EOF

Org seed finished: ${CREATED} tenant(s).
  Map: http://127.0.0.1:3000/architecture  (filter by tenant when UI supports it)
  Docs: docs/architecture-map-org.md

EOF
