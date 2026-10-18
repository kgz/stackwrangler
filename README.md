# awsbox

One **local AWS account** — real APIs, console on localhost, IaC against profile `local`. Learn and stage without a cloud bill.

North star: [docs/vision.md](docs/vision.md) · Board: [Project #8](https://github.com/users/kgz/projects/8/views/1)

```bash
./bin/awsbox up
./bin/awsbox console   # http://127.0.0.1:3000
aws --profile local … # SeaweedFS S3 :8333 · LocalEmu :4566
```

Emulator is **LocalEmu** (not LocalStack Community — we need IAM enforcement). Console buckets UI uses **SeaweedFS**; IaC/Lambda/S3 events use **LocalEmu S3**.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **Working** | Data plane + CLI smoke + console for the happy path |
| **Partial** | Works with known gaps (dual backends, bridge, limited authz) |
| **Control plane** | `create-*` / `describe-*` OK; little/no real traffic |
| **CLI + smoke** | Script/example works; **no console** (or thin) |
| **Console chrome** | Nav / empty page only |
| **Sidecar** | Real bytes via awsbox container, not native service listen |
| **Backlog** | Ticketed, not started |
| **Local smokes** | Proven with `./bin/*-smoke.sh` (no GitHub Actions e2e) |

---

## Platform / core

| Area | Status | Notes |
|------|--------|--------|
| `./bin/awsbox up` + profile `local` | **Working** | Compose + managed AWS profile |
| Console shell (AWS-look) | **Working** | Dark console frame |
| Dual S3 (SeaweedFS + LocalEmu) | **Partial** | UI → `:8333`; Lambda/IaC → `:4566` · debt [#143](https://github.com/kgz/awsl/issues/143) |
| IAM enforcement | **Partial** | deny-user lab only · workload roles debt [#144](https://github.com/kgz/awsl/issues/144) |
| Local smokes / Playwright | **Local smokes** | No GHA e2e (by design) |

---

## Storage & objects

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| S3 general purpose | SeaweedFS objects + parity script | Buckets / objects / preview | **Working** (UI) · **Partial** (vs LocalEmu S3 for events) |
| S3 specialty / Access Points / Lens | — | Empty states | **Console chrome** |
| Transfer Family | API + SFTP sidecar → S3 bridge | Servers list/detail | **Partial** + **Sidecar** (`docs/transfer.md`) · native keys: [#141](https://github.com/kgz/awsl/issues/141) |
| EFS / FSx / EBS | — | — | **Backlog** |

Smokes: `./bin/s3-parity.sh`, `./bin/transfer-smoke.sh`, `./bin/transfer-dataplane-smoke.sh`

---

## Compute & containers

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| Lambda | Docker invoke | Functions | **Working** (authz depth → [#144](https://github.com/kgz/awsl/issues/144)) |
| ECS | Docker tasks (terraform sample) | Clusters / services / tasks | **Partial** · depth [#146](https://github.com/kgz/awsl/issues/146) |
| EC2 | Docker-backed instances | Instances list | **Partial** · depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECR / EKS / Batch / App Runner / ASG | — | — | **Backlog** |

Smokes: Lambda via console/CLI · `./bin/ecs-smoke.sh` · `./bin/ec2-smoke.sh`

---

## Networking

| Service | Status |
|---------|--------|
| VPC / SG / AZ polish | **Backlog** |
| ALB / NLB / Classic ELB | **Backlog** |
| WAFv2 / Route 53 / CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

---

## Data stores

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| RDS (Postgres) | Docker DB via `RDS_DOCKER_BACKEND` | Databases + `psql` hint | **Partial** · create/Aurora debt [#145](https://github.com/kgz/awsl/issues/145) |
| DynamoDB / ElastiCache / other DBs | — | — | **Backlog** |

Smoke: `./bin/rds-smoke.sh` (needs host `psql`)

---

## Messaging & integration

| Service | Status |
|---------|--------|
| SQS / SNS / EventBridge / Step Functions / Kinesis / MSK / SES / AppSync | **Backlog** |

---

## Security & identity

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| IAM users + AccessDenied lab | Enforced on LocalEmu S3 demo | Users + lab | **Partial** |
| STS | Enabled | — | **Control plane** (polish backlog) |
| KMS / Secrets / Cognito / ACM / detection | — | — | **Backlog** |
| IAM Identity Center | — | — | **Backlog** |

Smoke: `./bin/iam-access-denied.sh`

---

## Observability & account

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| CloudWatch Logs | Log groups | Log groups | **Working** (basic) |
| API Gateway HTTP | APIs | HTTP APIs | **Partial** |
| Metrics / Alarms / SSM / CloudTrail / X-Ray / Orgs | — | — | **Backlog** |

---

## IaC & deploy

| Tool | Status |
|------|--------|
| Terraform S3+Lambda | **Working** (`examples/terraform/…`, local apply) |
| CloudFormation | **Partial** — stacks UI; write path [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) · audit [#147](https://github.com/kgz/awsl/issues/147) |
| CDK / SAM samples | **Working** (smokes against local CFN) |
| Pulumi / Ansible examples | **Backlog** |
| CodePipeline / Build / Deploy / Artifact | **Backlog** |

Smokes: `./bin/cfn-smoke.sh`, `./bin/cdk-smoke.sh`, `./bin/sam-smoke.sh`

---

## Org staging path (target)

VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS — epic [#90](https://github.com/kgz/awsl/issues/90) / path [#91](https://github.com/kgz/awsl/issues/91).

| Hop | Today |
|-----|--------|
| Transfer bytes | **Sidecar** SFTP → LocalEmu S3 |
| Lambda / S3 / ECS / RDS | **Partial**–**Working** pieces exist |
| Full E2E one smoke | **Backlog** |

---

## Quick start

Needs Docker + [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Optional: `psql`, `sshpass` for RDS / Transfer dataplane smokes.

```bash
cp .env.example .env   # first time; awsbox up also does this
./bin/awsbox up
./bin/awsbox console    # http://127.0.0.1:3000
aws --profile local s3 ls
./bin/awsbox down                 # keep profile
./bin/awsbox down --remove-profile
```

| What | Where |
|------|--------|
| S3 (console buckets) | `http://127.0.0.1:8333` SeaweedFS |
| LocalEmu (IAM, Lambda, CFN, Transfer, RDS, …) | `http://127.0.0.1:4566` |
| SFTP sidecar | `127.0.0.1:2222` (user `awsbox` / pass `awsboxpass`) |
| Console | `http://127.0.0.1:3000` |
| Profile | `local` |

If profile `local` exists and isn’t awsbox-managed: `./bin/awsbox up --force`.

### WSL / Docker

Ports bind to `127.0.0.1` on WSL. Use Docker Desktop with WSL integration (or engine in WSL).

---

## Board & workflow

```bash
./bin/board-status.sh in-progress <n>
./bin/board-audit.sh
./bin/setup-github-board.sh
```

OpenSpec: `/opsx-propose` · `/opsx-apply` · `/opsx-explore`  
Console mocks: `design/awsbox-console/` · `./bin/od-design-run.sh --issue <n> "…"`
