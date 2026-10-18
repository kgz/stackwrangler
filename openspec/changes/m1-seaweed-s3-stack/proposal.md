## Why

M1 is S3-only. MinIO community images are gone; use SeaweedFS (`weed mini`) in Docker and auto-write AWS profile `local` so the real `aws` CLI works.

## What Changes

- Docker Compose service running SeaweedFS S3 API on `127.0.0.1:8333`
- `bin/awsbox up|down|status` + `bin/awsbox-profile write|remove`
- Profile `local` with endpoint, keys, path-style, s3v4
- README smoke path

## Non-goals

- IAM / bucket policy UI
- Lambda / Serverless
- AWS-look console (#4 / #5)
- Exhaustive s3api parity matrix (#9)

## Capabilities

### New Capabilities

- `s3-stack`: Docker Compose SeaweedFS S3 service, ports, volume, health
- `aws-local-profile`: auto-configure / tear down AWS shared profile `local`

### Modified Capabilities

- (none)

## Impact

- `docker-compose.yml`, `.env.example`, `bin/awsbox*`
- Touches `~/.aws/credentials` + `config` for profile `local` only
- Backend swappable later without console changes
- Issue: #8
