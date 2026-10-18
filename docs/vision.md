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

**v1** (API + console slices) — **shipped**: S3 UI, IAM AccessDenied, Lambda, Logs, API Gateway.

**v1.5 — IaC path** (Terraform + compute samples — **shipped**):

| Scope | Intent |
|-------|--------|
| Terraform S3+Lambda | `examples/terraform/s3-lambda` + `./bin/iac-smoke.sh` |
| ECS / EC2 | `examples/terraform/ecs-nginx`, `ec2-hello` + smokes |

**v1.5 — CloudFormation / CDK / SAM** ([milestone](https://github.com/kgz/awsl/milestone/7)):

| Scope | Intent |
|-------|--------|
| Enable CFN on LocalEmu | `cloudformation` in `SERVICES` + profile endpoint |
| CFN example: S3 + Lambda | Mirror Terraform demo; `./bin/cfn-smoke.sh` |
| CDK / SAM samples | Thin wrappers over the same CFN path |

Same dual-S3 rule: stacks use LocalEmu `:4566`, not SeaweedFS.

**v2 S3 advanced**: specialty buckets, Access Points, Storage Lens, Batch Ops ship as empty states (no local API).

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
