## Context

Greenfield. Vision M1: local S3 via Docker, auto keys, real `aws` CLI. MinIO images archived → **SeaweedFS** (`weed mini`).

## Goals / Non-Goals

**Goals:**

- `./bin/awsbox up` starts SeaweedFS S3 on `127.0.0.1:8333`
- Writes AWS profile `local` (path-style, s3v4, endpoint_url)
- Tear-down via `awsbox down` (+ optional `--remove-profile`)

**Non-Goals:**

- Console UI, IAM learning UI
- Full s3api parity harness (#9)

## Decisions

1. **SeaweedFS over MinIO / S3Mock / Garage**
   - Maintained image, real keys (`InvalidAccessKeyId` on wrong key), single `mini` process.
   - S3Mock = no real auth; Garage = heavy bootstrap; MinIO = no public images.

2. **Compose service name `s3`**
   - Backend-agnostic name so image can change later without renames everywhere.

3. **Credentials via env**
   - `AWSBOX_ACCESS_KEY` / `AWSBOX_SECRET_KEY` in `.env` → compose `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for `weed mini`.

4. **Health: any HTTP on :8333**
   - Unauthenticated GET often returns 403; treat that as up.

5. **Shell scripts, not Node yet**
   - Fastest path; Node CLI can wrap later.

## Risks / Trade-offs

- [SeaweedFS quirks vs AWS] → #9 gap list
- [Profile `local` collision] → refuse unless `--force`
- [WSL ports] → bind `127.0.0.1:8333`
