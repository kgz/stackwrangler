#!/usr/bin/env bash
# Full e2e: SeaweedFS up → CLI parity → Playwright (console UI + CLI cross-checks).
# Usage: ./bin/e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> stack"
./bin/awsbox up --force

echo "==> CLI parity"
./smokes/s3/s3-parity.sh | tee docs/s3-parity.md

echo "==> Dual S3 split (Seaweed ≠ LocalEmu)"
./smokes/s3/s3-dual-endpoint-smoke.sh

echo "==> IAM AccessDenied"
./smokes/security/iam-access-denied.sh

echo "==> IAM SimulateCustomPolicy / SimulatePrincipalPolicy"
./smokes/security/iam-simulate-policy-smoke.sh

echo "==> IAM OIDC + PassRole"
./smokes/security/oidc-smoke.sh
./smokes/security/iam-permissions-boundary-key-smoke.sh

echo "==> Lambda smoke"
./smokes/lambda/lambda-smoke.sh

echo "==> Lambda deploy zip"
./smokes/lambda/lambda-deploy-smoke.sh

echo "==> Lambda authz (sad: missing s3:PutObject)"
./smokes/lambda/lambda-authz-smoke.sh

echo "==> Lambda trust aws:SourceAccount"
./smokes/lambda/lambda-trust-condition-smoke.sh

echo "==> Lambda trust aws:SourceArn"
./smokes/lambda/lambda-trust-sourcearn-smoke.sh

echo "==> Lambda VPC → host services (sad: unmapped name)"
./smokes/lambda/lambda-vpc-smoke.sh

echo "==> Logs smoke"
./smokes/logs/logs-smoke.sh

echo "==> API Gateway smoke"
./smokes/apigw/apigw-smoke.sh

echo "==> API Gateway REST (OpenAPI + authorizer; sad: no token / Deny / unknown)"
./smokes/apigw/apigw-rest-smoke.sh

echo "==> ECS smoke"
./smokes/compute/ecs-smoke.sh

echo "==> ECS authz (sad: empty taskRole PutObject)"
./smokes/compute/ecs-authz-smoke.sh

echo "==> ECS bridge no-iptables task-role (#254)"
./smokes/compute/ecs-bridge-no-iptables-authz-smoke.sh

echo "==> ECS taskdef (secrets / host ports / failed-start)"
./smokes/compute/ecs-taskdef-smoke.sh

echo "==> ECS host-network task-role creds (loopback, no DNAT)"
./smokes/compute/ecs-host-creds-smoke.sh

echo "==> ECS on EC2 (bridge NLB + CodeDeploy)"
./smokes/compute/ecs-ec2-smoke.sh

echo "==> CodeDeploy (Lambda canary DG + ECS blue/green)"
./smokes/compute/codedeploy-smoke.sh

echo "==> ECR push/pull + ECS image (sad: no BatchGetImage)"
./smokes/compute/ecr-smoke.sh

echo "==> Lambda ImageUri ECR pull (sad: no BatchGetImage)"
./smokes/lambda/lambda-ecr-smoke.sh

echo "==> Transfer authz (sad: empty role PutObject)"
./smokes/transfer/transfer-authz-smoke.sh

echo "==> RDS authz (sad: wrong password)"
./smokes/data/rds-authz-smoke.sh

echo "==> SQS smoke"
./smokes/messaging/sqs-smoke.sh

echo "==> SQS authz (sad: deny SendMessage)"
./smokes/messaging/sqs-authz-smoke.sh

echo "==> SNS / EventBridge / DynamoDB / SFN / Secrets / KMS / Kinesis"
./smokes/messaging/sns-smoke.sh && ./smokes/messaging/sns-authz-smoke.sh && ./smokes/messaging/sns-max-message-size-smoke.sh
./smokes/messaging/events-smoke.sh && ./smokes/messaging/events-authz-smoke.sh
./smokes/data/dynamodb-smoke.sh && ./smokes/data/dynamodb-authz-smoke.sh
./smokes/messaging/sfn-smoke.sh && ./smokes/messaging/sfn-authz-smoke.sh
./smokes/security/secrets-smoke.sh && ./smokes/security/secrets-authz-smoke.sh
./smokes/security/kms-smoke.sh && ./smokes/security/kms-authz-smoke.sh
./smokes/messaging/kinesis-smoke.sh && ./smokes/messaging/kinesis-authz-smoke.sh

echo "==> ACM request/import + API domain + ALB HTTPS ARN"
./smokes/security/acm-smoke.sh

echo "==> Logs / API GW / EC2 authz"
./smokes/logs/logs-authz-smoke.sh
./smokes/apigw/apigw-authz-smoke.sh
./smokes/compute/ec2-authz-smoke.sh

echo "==> EC2 smoke"
./smokes/compute/ec2-smoke.sh

echo "==> VPC routing"
./smokes/networking/vpc-routing-smoke.sh

echo "==> Security groups (allow SG A, refuse SG B, live reapply)"
./smokes/networking/sg-enforcement-smoke.sh
echo "==> ELBv2 data plane"
if [[ "${AWSBOX_ELBV2_E2E:-0}" == "1" ]]; then
	./smokes/networking/elbv2-smoke.sh
else
	echo "skip: set AWSBOX_ELBV2_E2E=1 (needs EC2 containers; blocked on beta by #299: https://github.com/kgz/awsl/issues/299)"
fi

echo "==> Prowler (isolated; skip if install blocked)"
./smokes/security/prowler-smoke.sh

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
