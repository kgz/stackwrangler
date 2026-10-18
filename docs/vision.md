# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. The console and the CLI talk to that same account.

Learning target: use real tools (`aws …`) against something that *feels* like AWS — without a real AWS bill.

End state: a **docker stack you run once** that auto-configures endpoints and API keys (profile `local`).

## Milestone 1 — fully mimic S3

Nothing else yet. No IAM UI / policy theatre.

| Layer | What |
|-------|------|
| API | **SeaweedFS** in Docker (`weed mini` S3 on `:8333`) — swappable later |
| Keys | Stack writes AWS profile `local` (endpoint + access key + secret) |
| CLI | Every `aws s3` / day-to-day `aws s3api` command works against it |
| UI | Console that **matches AWS S3 look and feel** — client only, same API calls |

```bash
./bin/awsbox up
aws --profile local s3 mb s3://demo
aws --profile local s3 ls
# open localhost console → S3 → same buckets
```

Wrong key → `InvalidAccessKeyId`. Missing bucket → S3 error shapes. Console clicks are the same API calls.

**Why SeaweedFS:** MinIO community images are gone / project archived. Backend is behind compose — swap to S3Mock / Garage / etc. without rewriting the console.

## Later (not M1)

- IAM / policies as a learning surface
- Lambda, API Gateway, CloudWatch Logs
- `serverless.yml` → deploy into the stack
- More services, one at a time

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Delivery design | OpenSpec changes |
| Console mocks | `design/awsbox-console/` (Open Design) |
| Product entry | `./bin/awsbox` → docker compose |
