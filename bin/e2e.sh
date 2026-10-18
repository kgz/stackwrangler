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

echo "==> IAM AccessDenied"
./bin/iam-access-denied.sh

echo "==> Lambda smoke"
./bin/lambda-smoke.sh

echo "==> Lambda deploy zip"
./bin/lambda-deploy-smoke.sh

echo "==> Logs smoke"
./bin/logs-smoke.sh

echo "==> API Gateway smoke"
./bin/apigw-smoke.sh

echo "==> ECS smoke"
./bin/ecs-smoke.sh

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
