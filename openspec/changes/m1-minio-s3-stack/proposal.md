## Why

M1 is S3-only. We need a dockerized S3 API (MinIO) that auto-writes AWS profile `local` so the real `aws` CLI works with zero manual key fiddling. LocalStack/IAM are out of scope until later.

## What Changes

- Add Docker Compose stack running MinIO (S3 API + optional console port unused by us)
- On start (compose or thin `awsbox up` wrapper): write profile `local` with endpoint, region, access key, secret
- Document `aws --profile local s3 …` smoke path
- No bucket policies / IAM

## Non-goals

- IAM, ACLs as a learning surface, bucket policies
- Lambda / API Gateway / Serverless
- AWS-look console UI (issues #4 / #5 — next)
- Exhaustive `aws s3api` parity matrix (issue #9 — next after stack is up)

## Capabilities

### New Capabilities

- `minio-stack`: Docker Compose MinIO service, ports, volumes, health
- `aws-local-profile`: auto-configure / tear down AWS shared profile `local` for this stack

### Modified Capabilities

- (none)

## Impact

- New `docker-compose.yml` (and maybe `bin/awsbox` later)
- Touches `~/.aws/credentials` + `config` for profile `local` only
- Unblocks #9 (CLI parity) and #4/#5 (console)
- Issue: #8
