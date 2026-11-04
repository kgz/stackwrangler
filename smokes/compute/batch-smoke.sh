#!/usr/bin/env bash
# #83: AWS Batch stub — compute environment + job queue create/describe (no job run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

TS="$(date +%s)"
CE="awsbox-batch-ce-${TS}"
JQ="awsbox-batch-jq-${TS}"
ROLE="awsbox-batch-svc-${TS}"
KEEP="${AWSBOX_BATCH_KEEP:-0}"
ROLE_ARN=""
VPC=""
SUB=""
SG=""

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws batch update-job-queue --job-queue "$JQ" --state DISABLED >/dev/null 2>&1 || true
	aws batch delete-job-queue --job-queue "$JQ" >/dev/null 2>&1 || true
	aws batch update-compute-environment --compute-environment "$CE" --state DISABLED >/dev/null 2>&1 || true
	aws batch delete-compute-environment --compute-environment "$CE" >/dev/null 2>&1 || true
	[[ -n "$ROLE_ARN" ]] && aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

VPC="$(aws ec2 create-vpc --cidr-block 10.83.16.0/20 --query 'Vpc.VpcId' --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.83.16.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "awsbox-batch-${TS}" --description "batch stub" --vpc-id "$VPC" --query 'GroupId' --output text)"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"batch.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" --query 'Role.Arn' --output text)"

CE_ARN="$(
	aws batch create-compute-environment \
		--compute-environment-name "$CE" \
		--type MANAGED \
		--state ENABLED \
		--service-role "$ROLE_ARN" \
		--compute-resources "type=FARGATE,maxvCpus=4,subnets=${SUB},securityGroupIds=${SG}" \
		--query 'computeEnvironmentArn' --output text
)"
[[ -n "$CE_ARN" && "$CE_ARN" != "None" ]]

JQ_ARN="$(
	aws batch create-job-queue \
		--job-queue-name "$JQ" \
		--state ENABLED \
		--priority 1 \
		--compute-environment-order order=1,computeEnvironment="$CE_ARN" \
		--query 'jobQueueArn' --output text
)"
[[ -n "$JQ_ARN" && "$JQ_ARN" != "None" ]]

FOUND="$(
	aws batch describe-job-queues --job-queues "$JQ" \
		--query 'jobQueues[0].jobQueueName' --output text
)"
[[ "$FOUND" == "$JQ" ]] || {
	echo "FAIL: describe-job-queues got ${FOUND}" >&2
	exit 1
}

echo "OK: batch compute-env + job-queue create/describe (${JQ})"
