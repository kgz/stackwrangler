# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. Console, CLI, and **IaC** (Terraform / CDK / SAM) talk to that same account.

Learning target: `terraform apply` / `cdk deploy` / `ansible-playbook` / `aws …` against something that *feels* like AWS — without a real AWS bill.

**Org staging gap this solves:** a large team tells a dev “implement X” (e.g. VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS via Serverless/CDK) but has no safe staging account and no way to run the stack locally. awsbox is that local account.

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
| [Containers+](https://github.com/kgz/awsl/milestone/13) | ECR, EKS, Batch/Beanstalk/App Runner/ASG; ECS/EC2 console |
| [Analytics](https://github.com/kgz/awsl/milestone/14) | OpenSearch, Athena/Glue, QuickSight/EMR stubs |
| [Org staging](https://github.com/kgz/awsl/milestone/19) | Multi-service learning path (SFTP→…→RDS); console nav gaps |
| [CFN write UI](https://github.com/kgz/awsl/milestone/20) | Create/Update/change sets/StackSets in console |
| [Code*](https://github.com/kgz/awsl/milestone/15) | CodePipeline / Build / Deploy / Artifact |
| [Data movement](https://github.com/kgz/awsl/milestone/16) | **Transfer Family (SFTP)**, Backup, DMS, DataSync |
| [Enterprise net](https://github.com/kgz/awsl/milestone/18) | TGW, VPN, PrivateLink, Lattice, Global Accelerator, Network Firewall |
| [FinOps/catalogs](https://github.com/kgz/awsl/milestone/21) | Identity Center, STS, Cost/Budgets, RAM, Service Catalog, AppConfig |
| [AI/ML stubs](https://github.com/kgz/awsl/milestone/17) | Bedrock, SageMaker, common AI APIs |
| [Niche IaC](https://github.com/kgz/awsl/milestone/22) | MWAA, Amplify, Lightsail, IoT, Media, WorkSpaces, Pinpoint, **Pulumi**, **Ansible** |

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
