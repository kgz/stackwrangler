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
| Dual S3 (SeaweedFS + LocalEmu) | **Documented split** | UI/`local` → `:8333`; Lambda/IaC → `:4566` · [docs/s3-backends.md](docs/s3-backends.md) · smoke `./bin/s3-dual-endpoint-smoke.sh` |
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

Smokes: `./bin/s3-parity.sh`, `./bin/s3-dual-endpoint-smoke.sh`, `./bin/transfer-smoke.sh`, `./bin/transfer-dataplane-smoke.sh`, `./bin/transfer-authz-smoke.sh`

---

## Compute & containers

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| Lambda | Docker invoke · VPC → host services ([docs/lambda-vpc.md](docs/lambda-vpc.md)) | Functions | **Working** (authz depth → [#144](https://github.com/kgz/awsl/issues/144)) · VPC isolation **Partial** ([#187](https://github.com/kgz/awsl/issues/187)) |
| ECS | Docker tasks · secrets/`valueFrom` · host ports · failed-start status | Clusters / services / tasks | **Partial** · secrets/host/status [#201](https://github.com/kgz/awsl/issues/201) · depth [#146](https://github.com/kgz/awsl/issues/146) |
| EC2 | Docker instances · IMDSv2 instance-profile creds · user data · SSM `SendCommand` | Instances list | **Partial** · console depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECR / EKS / Batch / App Runner / ASG | — | — | **Backlog** |

Smokes: Lambda via console/CLI · `./bin/lambda-vpc-smoke.sh` · `./bin/ecs-smoke.sh` · `./bin/ecs-authz-smoke.sh` · `./bin/ecs-taskdef-smoke.sh` · `./bin/ec2-smoke.sh` · `./bin/ec2-imds-smoke.sh` · `./bin/ec2-authz-smoke.sh`

---

## Networking

| Service | Status |
|---------|--------|
| VPC / SG / AZ polish | **Backlog** |
| Account mirror (`./bin/awsl mirror` / `apply`) | **Partial** — synthetic VPC/subnet/SG · [docs/mirror.md](docs/mirror.md) · real-account read [#220](https://github.com/kgz/awsl/issues/220) |
| ALB / NLB / Classic ELB | **Backlog** |
| WAFv2 / Route 53 / CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./bin/mirror-smoke.sh`

---

## Data stores

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| RDS (Postgres) | Docker DB via `RDS_DOCKER_BACKEND` | Databases + `psql` hint | **Partial** · create/Aurora debt [#145](https://github.com/kgz/awsl/issues/145) |
| RDS (MySQL / Aurora MySQL) | Docker DB · writer/reader · `rds!` secret | Databases + `mysql` hint | **Partial** · failover [#225](https://github.com/kgz/awsl/issues/225) · console create [#145](https://github.com/kgz/awsl/issues/145) |
| DynamoDB | put/get item | — | **Working** (CLI) · console [#174](https://github.com/kgz/awsl/issues/174) |
| ElastiCache / other DBs | — | — | **Backlog** |

Smoke: `./bin/rds-smoke.sh` · sad: `./bin/rds-authz-smoke.sh` (needs host `psql`) · MySQL/Aurora: `./bin/rds-mysql-smoke.sh` (needs host `mysql`)

---

## Messaging & integration

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| SQS | LocalEmu send/receive | — | **Working** (CLI) · console [#167](https://github.com/kgz/awsl/issues/167) · [docs/sqs.md](docs/sqs.md) |
| SNS | publish | — | **Working** (CLI) · console [#172](https://github.com/kgz/awsl/issues/172) |
| EventBridge | put-events + rule | — | **Working** (CLI) · console [#173](https://github.com/kgz/awsl/issues/173) |
| Step Functions | Pass state machine | — | **Working** (CLI) · console [#175](https://github.com/kgz/awsl/issues/175) |
| Kinesis | put/get records | — | **Working** (CLI) · console [#178](https://github.com/kgz/awsl/issues/178) |
| MSK / SES / AppSync | — | — | **Backlog** |

Smoke: `./bin/sqs-smoke.sh` · `./bin/sns-smoke.sh` · `./bin/events-smoke.sh` · `./bin/sfn-smoke.sh` · `./bin/kinesis-smoke.sh` (+ `*-authz-smoke.sh`)

---

## Security & identity

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| IAM users + AccessDenied lab | Enforced on LocalEmu S3 demo | Users + lab | **Partial** |
| IAM OIDC / web identity | `AssumeRoleWithWebIdentity` checks a local JWKS; trust `StringEquals`/`StringLike` on `<issuer>:sub` and `:aud`. `repo:org/*` matches every repo in the org (risky). `iam:PassRole` is limited by `iam:PassedToService` | — | **CLI + smoke** · [docs/oidc.md](docs/oidc.md) · service-origin `kms:ViaService` / `aws:SourceArn` [#223](https://github.com/kgz/awsl/issues/223) |
| STS | Enabled | — | **Control plane** (polish backlog) |
| KMS | encrypt/decrypt | — | **Working** (CLI) · console [#177](https://github.com/kgz/awsl/issues/177) |
| Secrets Manager | create/get | — | **Working** (CLI) · console [#176](https://github.com/kgz/awsl/issues/176) |
| Cognito / ACM / detection | — | — | **Backlog** |
| IAM Identity Center | — | — | **Backlog** |
| Prowler posture scan | Isolated CLI smoke vs LocalEmu | — | **Working** (scoped) · full catalog [#197](https://github.com/kgz/awsl/issues/197) · [docs/prowler.md](docs/prowler.md) |

Smoke: `./bin/iam-access-denied.sh` · `./bin/oidc-smoke.sh` · `./bin/prowler-smoke.sh` · real AWS (~$0): `./bin/aws-parity-iam-denied.sh` ([docs/aws-parity-agent-iam.md](docs/aws-parity-agent-iam.md))  
CFN parity (local + real, short-lived): `./bin/aws-parity-cfn-s3-lambda.sh` · sad: `./bin/aws-parity-cfn-authz.sh` ([docs/aws-parity-cfn.md](docs/aws-parity-cfn.md))

---

## Observability & account

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| CloudWatch Logs | Log groups | Log groups | **Working** (basic) · sad [#169](https://github.com/kgz/awsl/issues/169) |
| API Gateway HTTP | APIs | HTTP APIs | **Partial** · sad [#170](https://github.com/kgz/awsl/issues/170) |
| API Gateway REST (v1) | OpenAPI import · `aws_proxy` · REQUEST authorizers · custom domain Host + base path ([docs/apigw-rest.md](docs/apigw-rest.md)) | — ([#189](https://github.com/kgz/awsl/issues/189)) | **Partial** · Deny 401≠403 [#190](https://github.com/kgz/awsl/issues/190) |
| Metrics / Alarms / SSM / CloudTrail / Orgs (empty reads) | Enabled for scanners (Prowler) | — | **Partial** (read-empty) · [#198](https://github.com/kgz/awsl/issues/198) · [docs/prowler.md](docs/prowler.md) |
| X-Ray / deeper observability | — | — | **Backlog** |

---

## IaC & deploy

| Tool | Status |
|------|--------|
| Terraform S3+Lambda | **Working** (`examples/terraform/…`, local apply) |
| CloudFormation | **Partial** — failed create rolls back and delete-stack removes resources ([#212](https://github.com/kgz/awsl/issues/212)); in-place rollback / Snapshot [#228](https://github.com/kgz/awsl/issues/228); stacks UI; write path [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) · audit [#147](https://github.com/kgz/awsl/issues/147) |
| CDK / SAM samples | **Working** (smokes against local CFN) |
| Pulumi / Ansible examples | **Backlog** |
| CodePipeline / Build / Deploy / Artifact | **Backlog** |

Smokes: `./bin/cfn-smoke.sh`, `./bin/cfn-lifecycle-smoke.sh`, `./bin/cdk-smoke.sh`, `./bin/sam-smoke.sh`

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

Needs Docker + [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Optional: `psql`, `mysql`, `sshpass` for RDS / Transfer dataplane smokes.

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
./bin/gap-check.sh <n>    # before done — Partial/UI stubs → Debt tickets
./bin/board-audit.sh
./bin/setup-github-board.sh
```

Gap rubric: [docs/gap-check.md](docs/gap-check.md) ·  
**Is this path tested?** → [docs/test-paths.md](docs/test-paths.md) · grid: [docs/smoke-matrix.md](docs/smoke-matrix.md).  
Closing a ticket that leaves a bridge, disabled console action, or happy-only smoke must open a **Debt:** follow-up the same day.


OpenSpec: `/opsx-propose` · `/opsx-apply` · `/opsx-explore`  
Console mocks: `design/awsbox-console/` · `./bin/od-design-run.sh --issue <n> "…"`
