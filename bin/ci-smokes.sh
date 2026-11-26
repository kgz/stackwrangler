#!/usr/bin/env bash
# Curated local-only smokes for GitHub Actions (#807).
# Assumes stack is already up (workflow / local: ./bin/stackwrangler up).
# Full e2e (Playwright, Prowler, optional ELBv2) stays in ./bin/e2e.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

run() {
	echo "==> $*"
	"$@"
}

# Org-path brain + trust baseline
run ./smokes/s3/s3-org-path-brain-smoke.sh
run ./smokes/security/iam-access-denied.sh
run ./smokes/security/iam-simulate-policy-smoke.sh

# Compute / path hops
# ecs-smoke.sh (terraform + awsvpc nginx) stays local/e2e — GHA runners lose
# LocalEmu mid-apply. Authz covers the CI-critical ECS credential path.
run ./smokes/lambda/lambda-smoke.sh
run ./smokes/lambda/lambda-authz-smoke.sh
run ./smokes/compute/ecs-authz-smoke.sh
run ./smokes/transfer/transfer-authz-smoke.sh
run ./smokes/data/rds-authz-smoke.sh
run ./smokes/transfer/org-path-smoke.sh

# Core data + messaging (happy + authz)
run ./smokes/messaging/sqs-smoke.sh
run ./smokes/messaging/sqs-authz-smoke.sh
run ./smokes/messaging/sns-smoke.sh
run ./smokes/messaging/sns-authz-smoke.sh
run ./smokes/messaging/events-smoke.sh
run ./smokes/messaging/events-authz-smoke.sh
run ./smokes/data/dynamodb-smoke.sh
run ./smokes/data/dynamodb-authz-smoke.sh
run ./smokes/messaging/sfn-smoke.sh
run ./smokes/messaging/sfn-authz-smoke.sh
run ./smokes/security/secrets-smoke.sh
run ./smokes/security/secrets-authz-smoke.sh
run ./smokes/security/kms-smoke.sh
run ./smokes/security/kms-authz-smoke.sh

# API + network enforcement
run ./smokes/logs/logs-smoke.sh
run ./smokes/apigw/apigw-smoke.sh
run ./smokes/apigw/apigw-rest-smoke.sh
run ./smokes/networking/sg-enforcement-smoke.sh

echo "==> ci-smokes OK"
