## Why

S3 M1 is done. Next v1 track is IAM so learners hit real `AccessDenied` from wrong policies in CLI and console — the skill that unblocks Lambda execution roles later.

## What Changes

- LocalEmu service alongside SeaweedFS (`iam` API + STS; LocalEmu S3 only for policy demos; `IAM_ENFORCEMENT=1`)
- Profile `local`: SeaweedFS for S3, LocalEmu for IAM/STS (per-service endpoints)
- Console IAM slice: Users list + AccessDenied learning path (create deny policy → show error)
- CLI smoke: `aws --profile local iam …` and a scripted AccessDenied assertion
- `./bin/awsbox up` waits for both backends

## Non-goals

- Full IAM console parity (groups, identity providers, Identity Center)
- Replacing SeaweedFS for general-purpose buckets UI
- Lambda / API Gateway / CloudWatch (#19–#22)
- Exhaustive IAM API coverage

## Capabilities

### New Capabilities

- `iam-stack`: LocalStack Docker service for IAM/STS (+ S3 for policy demos), health, ports
- `iam-console`: IAM Users list + AccessDenied learning surface in the console
- `iam-access-denied`: CLI + console path where a deny policy yields `AccessDenied`

### Modified Capabilities

- `aws-local-profile`: per-service endpoints (S3 → SeaweedFS; IAM/STS → LocalStack)

## Impact

- `docker-compose.yml`, `.env.example`, `bin/awsbox*`, `bin/awsbox-profile`
- Console routes/sidebar for IAM; `@aws-sdk/client-iam` (+ S3 against LocalStack for demo)
- Issue: #18
