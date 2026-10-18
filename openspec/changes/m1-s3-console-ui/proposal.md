## Why

Stack + CLI work; the missing M1 piece is an AWS-look console so learning happens by clicking the same flows as real AWS. Issues #4 (frame) and #5 (S3 buckets/objects).

## What Changes

- Vite/React console app that mimics AWS dark console chrome + S3 Buckets UI
- Client of SeaweedFS via `@aws-sdk/client-s3` (ListBuckets, CreateBucket, ListObjectsV2, Put/Get/DeleteObject)
- Served on localhost; `awsbox up` prints / opens the URL
- Visual target: `design/awsbox-console/refs/aws-s3-console-dark-2026.png`

## Non-goals

- Real IAM / Directory / Table / Vector bucket types (stub nav only)
- Pixel-perfect AWS for every subpage
- Server-side proxy (browser talks to S3 endpoint with keys from env)

## Capabilities

### New Capabilities

- `console-shell`: global header, region, account id, S3 sidebar frame
- `console-s3`: general-purpose buckets table + object browser driven by S3 API

### Modified Capabilities

- (none)

## Impact

- New `console/` package; compose/README/`awsbox` touch for port `3000`
- Issues #4, #5
