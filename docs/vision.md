# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. The console, the CLI, and Serverless all talk to that same account.

Learning target: use real tools (`aws`, Serverless Framework) against something that *feels* like AWS — without a real AWS bill.

## Core loop

```
awsbox up
```

1. Reads `serverless.yml` you already have.
2. Starts the fake account (LocalStack for API + Lambda runtime).
3. Creates buckets, functions, IAM role, logs, API Gateway from that file.
4. Opens a console on localhost.
5. Leaves an AWS CLI profile named `local` pointed at the endpoint.

From then on you learn with the real tools:

```bash
aws s3 ls
aws lambda invoke --function-name upload-handler out.json
```

Wrong IAM → `AccessDenied`. Missing bucket → `NoSuchBucket`. Console clicks are the same API calls.

## Four parts under `awsbox`

| Part | What you see | What is actually running |
|------|--------------|--------------------------|
| Console | Service list, region, bucket browser, function page, log tail | Web app on localhost |
| API | Same requests the real CLI sends | S3, Lambda, IAM, logs, API Gateway |
| Runtime | Handler runs when bucket or URL is hit | Your code in a local Lambda container |
| Deploy | `serverless.yml` → buckets and functions | One shot at startup, then `awsbox deploy` after edits |

LocalStack already covers API + Lambda runtime. The missing piece is the **console** and the **single command** that deploys `serverless.yml` into LocalStack and leaves you in profile `local`.

## Console is only a client

`http://localhost:3000` → click S3 → paints the AWS-ish bucket screen from real S3 API calls:

| UI action | API |
|-----------|-----|
| Bucket table | `ListBuckets` |
| Open bucket | `ListObjectsV2` |
| Upload | `PutObject` |
| Download | `GetObject` |

Header, region dropdown, and account id are frame chrome. Point the same site at LocalStack (or MinIO) and the screen still works. Their own consoles look different because they are different websites — not because the API differs.

An AMI / EC2 page is the same idea pointed at a different local endpoint. S3 cannot answer `DescribeImages`.

## Scope (v1)

Only services in a typical Serverless starter you care about:

- S3
- Lambda
- IAM role Serverless creates
- CloudWatch Logs
- API Gateway

A region switcher and a fake account id make it feel like AWS. Two hundred other services do not.

## Limits while learning

- LocalStack is close on core calls and wrong on obscure ones — real AWS docs still win when a response looks odd.
- Anything not started is simply absent (e.g. SQS tutorial does nothing until that service is on).

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Delivery design | OpenSpec changes |
| Product CLI | `awsbox` |
