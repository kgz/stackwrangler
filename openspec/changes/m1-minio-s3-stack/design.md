## Context

Greenfield. Vision M1: MinIO in Docker, auto keys, real `aws` CLI. No permissions theatre yet.

## Goals / Non-Goals

**Goals:**

- `docker compose up` starts MinIO with fixed root credentials
- Helper writes AWS profile `local` (path-style S3, custom endpoint)
- Tear-down documented; optional profile removal

**Non-Goals:**

- Console UI, IAM, multi-tenant MinIO policies
- Full s3api parity harness (separate change / #9)

## Decisions

1. **MinIO over LocalStack for M1**
   - S3-only, mature docker image, no IAM surface we do not want yet.
   - Alternative: LocalStack S3 — pulls more services; deferred.

2. **Compose in repo root**
   - Service `minio`, image `minio/minio`, command `server /data --console-address :9001`
   - API `9000`, data volume `minio-data`. We do not use MinIO’s own console as the product UI.

3. **Credentials**
   - Default root user/password in `.env.example` (e.g. `awsbox` / `awsboxawsbox`); compose reads `.env`
   - Same values written into profile `local`
   - Region default `us-east-1` (AWS CLI happy path); overridable via `AWSBOX_REGION`

4. **Profile writer**
   - Small script `bin/awsbox-profile` (shell or Node later) invoked from `bin/awsbox up` / compose `post` docs
   - v1 acceptable: document `./bin/awsbox-profile write` after compose up; wrap in `awsbox up` in same change if cheap
   - Endpoint: `http://127.0.0.1:9000`; force path-style (`s3.addressing_style` / `AWS_ENDPOINT_URL` as supported by installed AWS CLI v2)

5. **AWS CLI v2 endpoint**
   - Prefer `aws configure set endpoint_url … --profile local` + env `AWS_ENDPOINT_URL` documented for newer CLIs
   - Smoke: `aws --profile local s3 mb s3://awsbox-smoke && aws --profile local s3 ls`

## Risks / Trade-offs

- [CLI version differences for endpoint_url] → Document both `endpoint_url` in config and `--endpoint-url` flag
- [Profile `local` collision] → Refuse overwrite unless `--force`
- [MinIO vs AWS quirks on obscure s3api] → Owned by #9 gap list, not this change
- [WSL Docker port publish] → Bind `127.0.0.1:9000:9000`

## Open Questions

- Ship `awsbox` CLI package in this change or shell scripts only? Prefer shell + compose for speed; Node CLI can wrap later.
