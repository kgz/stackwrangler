## Why

Nothing in the repo yet starts a local AWS-shaped account. Issue #2 needs `awsbox up` to bring up LocalStack and leave an AWS CLI profile named `local` so later console and Serverless work share one endpoint.

## What Changes

- Add an `awsbox` CLI with `up` / `down` / `status`
- On `up`: start LocalStack (Docker), wait until healthy, write AWS profile `local` (endpoint, fake account id, fake access keys)
- Document ports and profile usage in README
- Smoke check: `aws --profile local s3 ls` hits localhost

## Non-goals

- Console UI
- `serverless.yml` deploy
- Installing or wrapping the AWS CLI itself (caller must have `aws` + Docker)
- Any services beyond what LocalStack starts by default for this slice

## Capabilities

### New Capabilities

- `awsbox-cli`: lifecycle commands and LocalStack orchestration
- `aws-local-profile`: create/update/remove the `local` AWS shared-credentials profile pointed at the LocalStack endpoint

### Modified Capabilities

- (none — greenfield)

## Impact

- New package under repo root (CLI + docker-compose or LocalStack container config)
- Depends on Docker; optional `aws` CLI for smoke docs
- Touches `~/.aws/credentials` and `~/.aws/config` for profile `local` only
- Unblocks #3 (deploy) and #4 (console) which both need the same endpoint


## Superseded

Replaced by S3-first MinIO milestone (no LocalStack / IAM in M1).
