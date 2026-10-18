# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. Console, CLI, and **IaC** (Terraform / CDK / SAM) talk to that same account.

Learning target: `terraform apply` / `aws …` against something that *feels* like AWS — bucket + Lambda that actually talk to each other — without a real AWS bill.

End state: a **docker stack you run once** that auto-configures endpoints and API keys (profile `local`).

## What “done” looks like for you

```text
./bin/awsbox up
cd examples/terraform/s3-lambda   # (or your own module)
terraform apply                   # named bucket + Lambda that does work
aws --profile local …             # same resources visible in CLI + console
```

Later: same pattern for **ECS** (real Docker tasks) and **EC2** (container-backed instances) via LocalEmu.

## Architecture note (important)

| Surface | Backend today |
|---------|----------------|
| Console **General purpose buckets** UI | SeaweedFS `:8333` (AWS-look S3; Open/preview objects) |
| IAM / Lambda / Logs / API GW / **IaC S3+events** | LocalEmu `:4566` |

S3 ↔ Lambda “actually do things” (notifications, Lambda writing objects, etc.) must use **one** S3 backend. That path is **LocalEmu S3**. SeaweedFS stays the polished console buckets page until/unless we unify.

## Milestones (GitHub)

**Shipped**: S3 UI, IAM, Lambda, Logs, API Gateway, Terraform S3+Lambda, ECS, EC2, v2 S3 empty chrome.

**v1.5 — CloudFormation / CDK / SAM** ([#7](https://github.com/kgz/awsl/milestone/7)) — **shipped**:
`cloudformation` on LocalEmu; `examples/{cloudformation,cdk,sam}/s3-lambda` + `./bin/{cfn,cdk,sam}-smoke.sh`.

**v1 expansion** (LocalEmu enable + profile + smoke; console when useful). Stub APIs (ALB/NLB/WAF/CDN) still get tickets — document limits.

| Milestone | Covers |
|-----------|--------|
| [Networking](https://github.com/kgz/awsl/milestone/8) | VPC/AZs, ALB, NLB, Classic ELB, WAFv2, Route 53, Resolver, CloudFront |
| [Data stores](https://github.com/kgz/awsl/milestone/9) | DynamoDB, RDS, ElastiCache, EFS/FSx/EBS, other DB stubs |
| [Messaging](https://github.com/kgz/awsl/milestone/10) | SQS, SNS, EventBridge, Step Functions, Kinesis, MSK/MQ, SES/AppSync |
| [Security](https://github.com/kgz/awsl/milestone/11) | KMS, Secrets, Cognito, ACM, detection stubs |
| [Observability](https://github.com/kgz/awsl/milestone/12) | CW Metrics/Alarms, SSM, CloudTrail/Config, Orgs, X-Ray |
| [Containers+](https://github.com/kgz/awsl/milestone/13) | ECR, EKS, Batch/Beanstalk/App Runner/ASG |
| [Analytics](https://github.com/kgz/awsl/milestone/14) | OpenSearch, Athena/Glue, QuickSight/EMR stubs |

Same dual-S3 rule: IaC stacks use LocalEmu `:4566`, not SeaweedFS.

**v2 S3 advanced**: specialty buckets / Access Points / Storage Lens — empty states shipped.

```bash
./bin/awsbox up
./bin/awsbox console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Milestones | GitHub milestones |
| Delivery design | OpenSpec changes |
| Console mocks | `design/awsbox-console/` |
| IaC examples | `examples/` |
| Product entry | `./bin/awsbox` |
