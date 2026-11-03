#!/usr/bin/env bash
# Failed create rolls back, delete-stack removes resources, failed update status is honest.
# Usage: ./bin/cfn-lifecycle-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

STACKS=()
QUEUES=()

cleanup() {
	set +e
	for name in "${QUEUES[@]+"${QUEUES[@]}"}"; do
		url="$(aws sqs get-queue-url --queue-name "$name" --query QueueUrl --output text 2>/dev/null || true)"
		if [[ -n "$url" && "$url" != None ]]; then
			aws sqs delete-queue --queue-url "$url" >/dev/null 2>&1 || true
		fi
	done
	for name in "${STACKS[@]+"${STACKS[@]}"}"; do
		aws cloudformation delete-stack --stack-name "$name" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

wait_stack() {
	local name="$1"
	local status=""
	for _ in $(seq 1 40); do
		status="$(aws cloudformation describe-stacks --stack-name "$name" \
			--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)"
		case "$status" in
		*_COMPLETE | *_FAILED | GONE) echo "$status"; return 0 ;;
		esac
		sleep 1
	done
	echo "timeout:${status}" >&2
	return 1
}

table_exists() {
	aws dynamodb describe-table --table-name "$1" >/dev/null 2>&1
}

queue_exists() {
	aws sqs get-queue-url --queue-name "$1" >/dev/null 2>&1
}

# --- failed create: ROLLBACK_COMPLETE, created table removed, delete, recreate ---
FAIL_STACK="awsbox-cfn-life-fail-${TS}"
FAIL_TABLE="awsbox-cfn-life-${TS}"
STACKS+=("$FAIL_STACK")
cat >"/tmp/${FAIL_STACK}.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  GoodTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: ${FAIL_TABLE}
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: id
          AttributeType: S
      KeySchema:
        - AttributeName: id
          KeyType: HASH
  BadQueue:
    Type: AWS::SQS::Queue
    DependsOn: GoodTable
    Properties:
      QueueName: "bad queue ${TS}"
EOF

echo "==> create-stack ${FAIL_STACK} (one resource fails)"
aws cloudformation create-stack --stack-name "$FAIL_STACK" \
	--template-body "file:///tmp/${FAIL_STACK}.yaml" >/dev/null
FAIL_STATUS="$(wait_stack "$FAIL_STACK")"
echo "status=${FAIL_STATUS}"
[[ "$FAIL_STATUS" == ROLLBACK_COMPLETE ]]

if table_exists "$FAIL_TABLE"; then
	echo "FAIL: table ${FAIL_TABLE} still exists after rollback" >&2
	exit 1
fi

echo "==> delete-stack ${FAIL_STACK}"
aws cloudformation delete-stack --stack-name "$FAIL_STACK" >/dev/null
DEL_STATUS="$(wait_stack "$FAIL_STACK")"
echo "delete status=${DEL_STATUS}"
[[ "$DEL_STATUS" == GONE || "$DEL_STATUS" == DELETE_COMPLETE ]]

echo "==> recreate ${FAIL_STACK}"
cat >"/tmp/${FAIL_STACK}-ok.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  GoodTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: ${FAIL_TABLE}
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: id
          AttributeType: S
      KeySchema:
        - AttributeName: id
          KeyType: HASH
EOF
aws cloudformation create-stack --stack-name "$FAIL_STACK" \
	--template-body "file:///tmp/${FAIL_STACK}-ok.yaml" >/dev/null
OK_STATUS="$(wait_stack "$FAIL_STACK")"
echo "recreate status=${OK_STATUS}"
[[ "$OK_STATUS" == CREATE_COMPLETE ]]
table_exists "$FAIL_TABLE"

aws cloudformation delete-stack --stack-name "$FAIL_STACK" >/dev/null
DEL2="$(wait_stack "$FAIL_STACK")"
[[ "$DEL2" == GONE || "$DEL2" == DELETE_COMPLETE ]]
if table_exists "$FAIL_TABLE"; then
	echo "FAIL: table ${FAIL_TABLE} left after delete-stack" >&2
	exit 1
fi

# --- failed update must not report UPDATE_COMPLETE ---
UPD_STACK="awsbox-cfn-life-upd-${TS}"
UPD_QUEUE="awsbox-cfn-life-upd-${TS}"
STACKS+=("$UPD_STACK")
QUEUES+=("$UPD_QUEUE")
cat >"/tmp/${UPD_STACK}.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  GoodQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: ${UPD_QUEUE}
EOF
cat >"/tmp/${UPD_STACK}-bad.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  GoodQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: ${UPD_QUEUE}
  BadQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: "bad queue upd ${TS}"
EOF

echo "==> update-stack ${UPD_STACK} (add a failing resource)"
aws cloudformation create-stack --stack-name "$UPD_STACK" \
	--template-body "file:///tmp/${UPD_STACK}.yaml" >/dev/null
[[ "$(wait_stack "$UPD_STACK")" == CREATE_COMPLETE ]]
aws cloudformation update-stack --stack-name "$UPD_STACK" \
	--template-body "file:///tmp/${UPD_STACK}-bad.yaml" >/dev/null
UPD_STATUS="$(wait_stack "$UPD_STACK")"
echo "update status=${UPD_STATUS}"
[[ "$UPD_STATUS" == UPDATE_ROLLBACK_COMPLETE ]]
queue_exists "$UPD_QUEUE"
if queue_exists "bad queue upd ${TS}"; then
	echo "FAIL: invalid queue was created" >&2
	exit 1
fi

# --- delete-stack honours DeletionPolicy Retain ---
RET_STACK="awsbox-cfn-life-ret-${TS}"
KEEP_QUEUE="awsbox-cfn-life-keep-${TS}"
DROP_QUEUE="awsbox-cfn-life-drop-${TS}"
STACKS+=("$RET_STACK")
QUEUES+=("$KEEP_QUEUE")
cat >"/tmp/${RET_STACK}.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  KeepQueue:
    Type: AWS::SQS::Queue
    DeletionPolicy: Retain
    Properties:
      QueueName: ${KEEP_QUEUE}
  DropQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: ${DROP_QUEUE}
EOF

echo "==> delete-stack ${RET_STACK} (Retain + delete)"
aws cloudformation create-stack --stack-name "$RET_STACK" \
	--template-body "file:///tmp/${RET_STACK}.yaml" >/dev/null
[[ "$(wait_stack "$RET_STACK")" == CREATE_COMPLETE ]]
aws cloudformation delete-stack --stack-name "$RET_STACK" >/dev/null
RET_STATUS="$(wait_stack "$RET_STACK")"
echo "retain delete status=${RET_STATUS}"
[[ "$RET_STATUS" == GONE || "$RET_STATUS" == DELETE_COMPLETE ]]
queue_exists "$KEEP_QUEUE"
if queue_exists "$DROP_QUEUE"; then
	echo "FAIL: ${DROP_QUEUE} still exists after delete-stack" >&2
	exit 1
fi

echo "OK: cfn lifecycle (rollback, delete, retain, update status)"
