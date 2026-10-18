# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. The console and the CLI talk to that same account.

Learning target: use real tools (`aws …`) against something that *feels* like AWS — without a real AWS bill.

End state: a **docker stack you run once** that auto-configures endpoints and API keys (profile `local`).

## Milestone 1 — fully mimic S3

Nothing else yet. No IAM, no bucket policies, no Lambda.

| Layer | What |
|-------|------|
| API | **MinIO** in Docker (S3-compatible) |
| Keys | Stack writes AWS profile `local` (endpoint + access key + secret) |
| CLI | Every `aws s3` / day-to-day `aws s3api` command works against it |
| UI | Console that **matches AWS S3 look and feel** — client only, same API calls |

```bash
docker compose up   # or later: awsbox up
aws --profile local s3 mb s3://demo
aws --profile local s3 ls
# open localhost console → S3 → same buckets
```

Wrong/missing bucket still returns real S3 error shapes (`NoSuchBucket`, etc.). Permissions come later.

## Later (not M1)

- IAM / policies (`AccessDenied` when you wire them)
- Lambda, API Gateway, CloudWatch Logs
- `serverless.yml` → deploy into the stack
- More services, one at a time

Console stays a **client**. MinIO (or later LocalStack) holds the bytes. Point the same UI at any S3-compatible endpoint.

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Delivery design | OpenSpec changes |
| Console mocks | `design/awsbox-console/` (Open Design) |
| Product entry | docker compose → later `awsbox` CLI |
