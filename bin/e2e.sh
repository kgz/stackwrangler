#!/usr/bin/env bash
# Full e2e: SeaweedFS up → CLI parity → Playwright (console UI + CLI cross-checks).
# Usage: ./bin/e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> stack"
./bin/awsbox up --force

echo "==> CLI parity"
./bin/s3-parity.sh | tee docs/s3-parity.md

echo "==> Dual S3 split (Seaweed ≠ LocalEmu)"
./bin/s3-dual-endpoint-smoke.sh

echo "==> IAM AccessDenied"
./bin/iam-access-denied.sh

echo "==> IAM OIDC + PassRole"
./bin/oidc-smoke.sh

echo "==> Lambda smoke"
./bin/lambda-smoke.sh

echo "==> Lambda deploy zip"
./bin/lambda-deploy-smoke.sh

echo "==> Lambda authz (sad: missing s3:PutObject)"
./bin/lambda-authz-smoke.sh

echo "==> Lambda trust aws:SourceAccount"
./bin/lambda-trust-condition-smoke.sh

echo "==> Lambda trust aws:SourceArn"
./bin/lambda-trust-sourcearn-smoke.sh

echo "==> Lambda VPC → host services (sad: unmapped name)"
./bin/lambda-vpc-smoke.sh

echo "==> Logs smoke"
./bin/logs-smoke.sh

echo "==> API Gateway smoke"
./bin/apigw-smoke.sh

echo "==> API Gateway REST (OpenAPI + authorizer; sad: no token / Deny / unknown)"
./bin/apigw-rest-smoke.sh

echo "==> ECS smoke"
./bin/ecs-smoke.sh

echo "==> ECS authz (sad: empty taskRole PutObject)"
./bin/ecs-authz-smoke.sh

echo "==> ECS taskdef (secrets / host ports / failed-start)"
./bin/ecs-taskdef-smoke.sh

echo "==> ECS host-network task-role creds (loopback, no DNAT)"
./bin/ecs-host-creds-smoke.sh

echo "==> ECS on EC2 (bridge NLB + CodeDeploy)"
./bin/ecs-ec2-smoke.sh

echo "==> CodeDeploy (Lambda canary DG + ECS blue/green)"
./bin/codedeploy-smoke.sh

echo "==> ECR push/pull + ECS image (sad: no BatchGetImage)"
./bin/ecr-smoke.sh

echo "==> Transfer authz (sad: empty role PutObject)"
./bin/transfer-authz-smoke.sh

echo "==> RDS authz (sad: wrong password)"
./bin/rds-authz-smoke.sh

echo "==> SQS smoke"
./bin/sqs-smoke.sh

echo "==> SQS authz (sad: deny SendMessage)"
./bin/sqs-authz-smoke.sh

echo "==> SNS / EventBridge / DynamoDB / SFN / Secrets / KMS / Kinesis"
./bin/sns-smoke.sh && ./bin/sns-authz-smoke.sh && ./bin/sns-max-message-size-smoke.sh
./bin/events-smoke.sh && ./bin/events-authz-smoke.sh
./bin/dynamodb-smoke.sh && ./bin/dynamodb-authz-smoke.sh
./bin/sfn-smoke.sh && ./bin/sfn-authz-smoke.sh
./bin/secrets-smoke.sh && ./bin/secrets-authz-smoke.sh
./bin/kms-smoke.sh && ./bin/kms-authz-smoke.sh
./bin/kinesis-smoke.sh && ./bin/kinesis-authz-smoke.sh

echo "==> ACM request/import + API domain + ALB HTTPS ARN"
./bin/acm-smoke.sh

echo "==> Logs / API GW / EC2 authz"
./bin/logs-authz-smoke.sh
./bin/apigw-authz-smoke.sh
./bin/ec2-authz-smoke.sh

echo "==> EC2 smoke"
./bin/ec2-smoke.sh

echo "==> VPC routing"
./bin/vpc-routing-smoke.sh

echo "==> Security groups (allow SG A, refuse SG B, live reapply)"
./bin/sg-enforcement-smoke.sh
echo "==> ELBv2 data plane"
if [[ "${AWSBOX_ELBV2_E2E:-0}" == "1" ]]; then
	./bin/elbv2-smoke.sh
else
	echo "skip: set AWSBOX_ELBV2_E2E=1 (needs EC2 containers; blocked on beta by #299: https://github.com/kgz/awsl/issues/299)"
fi

echo "==> Prowler (isolated; skip if install blocked)"
./bin/prowler-smoke.sh

echo "==> console deps"
if [[ ! -d console/node_modules ]]; then
	(cd console && yarn install)
fi

echo "==> Playwright"
(
	cd console
	yarn playwright test
)

echo "==> e2e OK"
