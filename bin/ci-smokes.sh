#!/usr/bin/env bash
# Curated local-only smokes for GitHub Actions (#807).
# Assumes stack is already up (workflow / local: ./bin/stackwrangler up).
# Full e2e (Playwright, Prowler, optional ELBv2) stays in ./bin/e2e.sh.
#
# GHA runners (~7GiB) OOM when LocalEmu competes with docker builds / RDS
# sidecars — keep this list CLI-only. Heavier path (ECS terraform, org-path
# E2E, RDS authz, SG+RDS) stays in local smokes / e2e.
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

# Compute (no task-image builds)
run ./smokes/lambda/lambda-smoke.sh
run ./smokes/lambda/lambda-authz-smoke.sh
run ./smokes/transfer/transfer-authz-smoke.sh

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

# API + logs (no RDS / docker build)
run ./smokes/logs/logs-smoke.sh
run ./smokes/apigw/apigw-smoke.sh
run ./smokes/apigw/apigw-rest-smoke.sh

echo "==> ci-smokes OK"
