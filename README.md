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


## Platform / core

| Area | Status | Notes |
|------|--------|--------|
| `./bin/awsbox up` + profile `local` | **Working** | Compose + managed AWS profile |
| Console shell (AWS-look) | **Working** | Dark console frame |
| Console labels | **Working** | `AWSBOX_LABELS` file kept outside the repo · [docs/labels.md](docs/labels.md) · `./bin/labels-smoke.sh` |
| Dual S3 (SeaweedFS + LocalEmu) | **Documented split** | UI/`local` → `:8333`; Lambda/IaC → `:4566` · [docs/s3-backends.md](docs/s3-backends.md) · smoke `./bin/s3-dual-endpoint-smoke.sh` |
| IAM enforcement | **Partial** | resource policies `./bin/resource-policy-smoke.sh` · cross-account [#233](https://github.com/kgz/awsl/issues/233) · workload roles [#144](https://github.com/kgz/awsl/issues/144) |
| Custom resource IDs + account in ARNs | **Working** | `_custom_id_` tag · [docs/custom-ids.md](docs/custom-ids.md) · `./bin/custom-id-smoke.sh` |
| Local smokes / Playwright | **Local smokes** | No GHA e2e (by design) |


## Storage & objects

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| S3 general purpose | SeaweedFS objects + parity script | Buckets / objects / preview | **Working** (UI) · **Partial** (vs LocalEmu S3 for events) |
| S3 specialty / Access Points / Lens | — | Empty states | **Console chrome** |
| Transfer Family | API + native SFTP (SSH keys) → S3; outbound connectors (`StartFileTransfer` → remote SFTP) | Servers list/detail · connectors: [#313](https://github.com/kgz/awsl/issues/313) | **Partial** (`docs/transfer.md`) · console user/key [#321](https://github.com/kgz/awsl/issues/321) · LOGICAL/IdP/authz [#322](https://github.com/kgz/awsl/issues/322) · retrieve/AS2 [#314](https://github.com/kgz/awsl/issues/314) |
| EFS / FSx / EBS | — | — | **Backlog** |

Smokes: `./bin/s3-parity.sh`, `./bin/s3-dual-endpoint-smoke.sh`, `./bin/transfer-smoke.sh`, `./bin/transfer-key-smoke.sh`, `./bin/transfer-dataplane-smoke.sh`, `./bin/transfer-authz-smoke.sh`, `./bin/transfer-connector-smoke.sh`


## Compute & containers

| Lambda | Docker invoke · VPC → host services ([docs/lambda-vpc.md](docs/lambda-vpc.md)) | Functions | **Working** (authz depth → [#144](https://github.com/kgz/awsl/issues/144)) · VPC isolation **Partial** ([#187](https://github.com/kgz/awsl/issues/187)) |
| EC2 | Docker instances · IMDSv2 instance-profile creds · user data · SSM `SendCommand` | Instances list | **Partial** · console depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECS | Docker tasks · secrets/`valueFrom` · host ports · EC2 container instances · desiredCount replacement · bridge ports → target groups · CodeDeploy blue/green · pull from ECR URI | Clusters / services / tasks | **Partial** · awsvpc ENI [#268](https://github.com/kgz/awsl/issues/268) · EC2 services [#207](https://github.com/kgz/awsl/issues/207) · bridge targets vs instance-IP health [#247](https://github.com/kgz/awsl/issues/247) · VPC NLB listeners [#203](https://github.com/kgz/awsl/issues/203) · depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECR | create-repository · `get-login-password` · push/pull `127.0.0.1:5000/<repo>` · ECS task image `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` (needs `ecr:BatchGetImage`) | — | **Partial** · push the repositoryUri hostname [#218](https://github.com/kgz/awsl/issues/218) · Lambda image authz [#219](https://github.com/kgz/awsl/issues/219) · console [#217](https://github.com/kgz/awsl/issues/217) |
| EKS / Batch / App Runner / ASG | — | — | **Backlog** |

Smokes: Lambda via console/CLI · `./bin/lambda-vpc-smoke.sh` · `./bin/ecs-smoke.sh` · `./bin/ecs-authz-smoke.sh` · `./bin/ecs-taskdef-smoke.sh` · `./bin/ecs-host-creds-smoke.sh` · `./bin/ecs-ec2-smoke.sh` · `./bin/ec2-smoke.sh` · `./bin/ec2-imds-smoke.sh` · `./bin/ec2-authz-smoke.sh` · `./bin/ecr-smoke.sh` · `./bin/vpc-routing-smoke.sh` · `./bin/sg-enforcement-smoke.sh` · `./bin/vpce-private-dns-smoke.sh` · `./bin/elbv2-smoke.sh`


## Networking

| Service | Status |
|---------|--------|
| Account mirror (`./bin/awsl mirror` / `apply`) | **Partial** — synthetic VPC/subnet/RT/SG + fixture tags · [docs/mirror.md](docs/mirror.md) · `./bin/mirror-tags-smoke.sh` · real-account read [#220](https://github.com/kgz/awsl/issues/220) |
| VPC routes / peering / NAT | **Partial** · [docs/vpc-routing.md](docs/vpc-routing.md) · gateway endpoints / Lambda egress [#230](https://github.com/kgz/awsl/issues/230) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC security groups | **Partial** · [docs/sg-enforcement.md](docs/sg-enforcement.md) · NLB client IP [#236](https://github.com/kgz/awsl/issues/236) · VPC Lambda [#237](https://github.com/kgz/awsl/issues/237) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC Interface endpoint private DNS | **Partial** · [docs/vpce-private-dns.md](docs/vpce-private-dns.md) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC / AZ polish | **Backlog** |
| ALB / NLB / Classic ELB | **Partial** · [docs/elbv2.md](docs/elbv2.md) · console [#241](https://github.com/kgz/awsl/issues/241) · TLS ACM [#242](https://github.com/kgz/awsl/issues/242) · HTTP health [#243](https://github.com/kgz/awsl/issues/243) · ECS bridge smoke loopback forwarder [#247](https://github.com/kgz/awsl/issues/247) |
| Route 53 private zones | **Partial** — associated VPC only · `./bin/r53-private-smoke.sh` · [docs/r53-private.md](docs/r53-private.md) · console/Lambda [#245](https://github.com/kgz/awsl/issues/245) · API Gateway alias / public zones [#300](https://github.com/kgz/awsl/issues/300) |
| WAFv2 | **Partial** — create/associate API GW stage · rule eval **not** real edge WAF · [docs/waf.md](docs/waf.md) · console [#324](https://github.com/kgz/awsl/issues/324) · CFN [#325](https://github.com/kgz/awsl/issues/325) · edge eval [#326](https://github.com/kgz/awsl/issues/326) |
| CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./bin/mirror-smoke.sh` · `./bin/mirror-tags-smoke.sh` · `./bin/r53-private-smoke.sh` · `./bin/waf-smoke.sh` · `./bin/waf-authz-smoke.sh`
| Route 53 hosted zones + records | **Partial** — public A/alias/CNAME + dig in-emulator · `./bin/route53-smoke.sh` · [docs/r53.md](docs/r53.md) · console [#245](https://github.com/kgz/awsl/issues/245) · host dig / API GW alias [#300](https://github.com/kgz/awsl/issues/300) |
| WAFv2 / CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./bin/mirror-smoke.sh` · `./bin/mirror-tags-smoke.sh` · `./bin/route53-smoke.sh` · `./bin/r53-private-smoke.sh`


## Data stores

| RDS (Postgres) | Docker DB via `RDS_DOCKER_BACKEND` | Databases + `psql` hint | **Partial** · create/Aurora debt [#145](https://github.com/kgz/awsl/issues/145) |
| RDS (MySQL / Aurora MySQL) | Docker DB · writer/reader · `rds!` secret | Databases + `mysql` hint | **Partial** · failover [#225](https://github.com/kgz/awsl/issues/225) · console create [#145](https://github.com/kgz/awsl/issues/145) |
| DynamoDB | put/get · GSI query · scan filter · conditional writes · UpdateItem expressions · TransactWriteItems · TTL sweep · IAM on table/index ARNs | — | **Working** (CLI) · console [#174](https://github.com/kgz/awsl/issues/174) · `./bin/dynamodb-depth-smoke.sh` · Batch/Transact table-scoped IAM [#306](https://github.com/kgz/awsl/issues/306) · index `aws:ResourceTag` [#307](https://github.com/kgz/awsl/issues/307) |
| ElastiCache / other DBs | — | — | **Backlog** |

Smoke: `./bin/rds-smoke.sh` · sad: `./bin/rds-authz-smoke.sh` (needs host `psql`) · MySQL/Aurora: `./bin/rds-mysql-smoke.sh` (needs host `mysql`)


## Messaging & integration

| SQS | LocalEmu send/receive | — | **Working** (CLI) · console [#167](https://github.com/kgz/awsl/issues/167) · [docs/sqs.md](docs/sqs.md) |
| SNS | publish · SQS fan-out (queue policy / `SourceArn`) | — | **Working** (CLI) · console [#172](https://github.com/kgz/awsl/issues/172) · `./bin/sns-sqs-fanout-smoke.sh` |
| EventBridge | put-events + rule · scheduled `rate()` rule → Lambda (disable stops it; no invoke permission = no fire) | — | **Working** (CLI) · console [#173](https://github.com/kgz/awsl/issues/173) · [slice](examples/serverless-v3-rest/slices/schedule/README.md) · cadence [#317](https://github.com/kgz/awsl/issues/317) |
| Step Functions | Pass state machine | — | **Working** (CLI) · console [#175](https://github.com/kgz/awsl/issues/175) |
| Kinesis | put/get records | — | **Working** (CLI) · console [#178](https://github.com/kgz/awsl/issues/178) |
| MSK / SES / AppSync | — | — | **Backlog** |

Smoke: `./bin/sqs-smoke.sh` · `./bin/sns-smoke.sh` · `./bin/sns-sqs-fanout-smoke.sh` · `./bin/events-smoke.sh` · `./bin/sfn-smoke.sh` · `./bin/kinesis-smoke.sh` · `./bin/dynamodb-depth-smoke.sh` · `./bin/events-schedule-smoke.sh` · `./bin/sqs-lambda-dlq-smoke.sh` (+ `*-authz-smoke.sh`)
Smoke: `./bin/sqs-smoke.sh` · `./bin/sqs-lambda-dlq-smoke.sh` · `./bin/sns-smoke.sh` · `./bin/events-smoke.sh` · `./bin/sfn-smoke.sh` · `./bin/kinesis-smoke.sh` · `./bin/dynamodb-depth-smoke.sh` · `./bin/events-schedule-smoke.sh` · `./bin/sns-sqs-fanout-smoke.sh` (+ `*-authz-smoke.sh`)


## Security & identity

| IAM users + AccessDenied lab | Enforced on LocalEmu S3 demo | Users + lab | **Partial** · resource policies `./bin/resource-policy-smoke.sh` · workload roles [#144](https://github.com/kgz/awsl/issues/144) |
| IAM OIDC / web identity | `AssumeRoleWithWebIdentity` checks a local JWKS; trust `StringEquals`/`StringLike` on `<issuer>:sub` and `:aud`. `repo:org/*` matches every repo in the org (risky). `iam:PassRole` is limited by `iam:PassedToService` | — | **CLI + smoke** · [docs/oidc.md](docs/oidc.md) · service-origin `kms:ViaService` / `aws:SourceArn` [#223](https://github.com/kgz/awsl/issues/223) |
| STS | Enabled | — | **Control plane** (polish backlog) |
| KMS | encrypt/decrypt · key policy on Encrypt/Decrypt/GenerateDataKey | — | **Partial** · key policy `./bin/resource-policy-smoke.sh` · console [#177](https://github.com/kgz/awsl/issues/177) |
| Secrets Manager | create/get · resource policy on Get/Describe | — | **Partial** · resource policy `./bin/resource-policy-smoke.sh` · console [#176](https://github.com/kgz/awsl/issues/176) |
| Multiple accounts | Key→account, isolated state, cross-account AssumeRole | — | **CLI + smoke** · [docs/multi-account.md](docs/multi-account.md) |
| ACM | request / import / describe / list · ARN on API custom domain + ALB HTTPS listener ([docs/acm.md](docs/acm.md)) | — ([#333](https://github.com/kgz/awsl/issues/333)) | **Partial** · TLS handshake [#242](https://github.com/kgz/awsl/issues/242) |
| Cognito / detection | — | — | **Backlog** |
| IAM Identity Center | — | — | **Backlog** |
| Prowler posture scan | Isolated CLI smoke vs LocalEmu | — | **Working** (scoped) · full catalog [#197](https://github.com/kgz/awsl/issues/197) · [docs/prowler.md](docs/prowler.md) |

Smoke: `./bin/iam-access-denied.sh` · `./bin/resource-policy-smoke.sh` · `./bin/oidc-smoke.sh` · `./bin/acm-smoke.sh` · `./bin/prowler-smoke.sh` · `./bin/multi-account-smoke.sh` · real AWS (~$0): `./bin/aws-parity-iam-denied.sh` ([docs/aws-parity-agent-iam.md](docs/aws-parity-agent-iam.md))  
CFN parity (local + real, short-lived): `./bin/aws-parity-cfn-s3-lambda.sh` · sad: `./bin/aws-parity-cfn-authz.sh` ([docs/aws-parity-cfn.md](docs/aws-parity-cfn.md))


## Observability & account

| CloudWatch Logs | Log groups | Log groups | **Working** (basic) · sad [#169](https://github.com/kgz/awsl/issues/169) |
| API Gateway HTTP | APIs | HTTP APIs | **Partial** · sad [#170](https://github.com/kgz/awsl/issues/170) |
| API Gateway REST (v1) | OpenAPI import · `aws_proxy` · REQUEST authorizers · custom domain Host + base path · VPC_LINK → NLB · API keys + usage plans (`x-api-key`, throttle, quota; IAM `apigateway:POST/GET/DELETE` on `/apikeys`, `/usageplans`) ([docs/apigw-rest.md](docs/apigw-rest.md)) | — ([#189](https://github.com/kgz/awsl/issues/189), keys [#310](https://github.com/kgz/awsl/issues/310)) | **Partial** · Deny 401≠403 [#190](https://github.com/kgz/awsl/issues/190) · ENI IP [#268](https://github.com/kgz/awsl/issues/268) · usage reporting [#309](https://github.com/kgz/awsl/issues/309) · IAM breadth [#311](https://github.com/kgz/awsl/issues/311) |
| API Gateway REST (v1) | OpenAPI import · `aws_proxy` · REQUEST authorizers · custom domain Host + base path · VPC_LINK → NLB ([docs/apigw-rest.md](docs/apigw-rest.md)) | — ([#189](https://github.com/kgz/awsl/issues/189)) | **Partial** · ENI IP [#268](https://github.com/kgz/awsl/issues/268) |
| Metrics / Alarms / SSM / CloudTrail / Orgs (empty reads) | Enabled for scanners (Prowler) | — | **Partial** (read-empty) · [#198](https://github.com/kgz/awsl/issues/198) · [docs/prowler.md](docs/prowler.md) |
| X-Ray / deeper observability | — | — | **Backlog** |

Smokes: `./bin/apigw-smoke.sh` · `./bin/apigw-authz-smoke.sh` · `./bin/apigw-rest-smoke.sh` · `./bin/apigw-nlb-ecs-smoke.sh` · `./bin/apigw-usage-plan-smoke.sh`


## IaC & deploy

| Tool | Status |
|------|--------|
| Terraform S3+Lambda | **Working** (`examples/terraform/…`, local apply) |
| Terraform S3 backend + lock | **Working** ([docs/terraform-awsbox.md](docs/terraform-awsbox.md), `examples/terraform/awsbox-backend/`) |
| CloudFormation | **Partial** — failed create rolls back and delete-stack removes resources ([#212](https://github.com/kgz/awsl/issues/212)); in-place rollback / Snapshot [#228](https://github.com/kgz/awsl/issues/228); stacks UI; write path [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) · audit [#147](https://github.com/kgz/awsl/issues/147) |
| CDK / SAM samples | **Working** (smokes against local CFN) |
| Pulumi / Ansible examples | **Backlog** |
| CodePipeline / Build / Deploy / Artifact | **Backlog** |

Smokes: `./bin/iac-smoke.sh`, `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh`, `./bin/cfn-smoke.sh`, `./bin/cfn-lifecycle-smoke.sh`, `./bin/cdk-smoke.sh`, `./bin/sam-smoke.sh`


## Org staging path (target)

VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS — epic [#90](https://github.com/kgz/awsl/issues/90) / path [#91](https://github.com/kgz/awsl/issues/91).

| Hop | Today |
|-----|--------|
| Transfer bytes | **Partial** native SSH-key SFTP → LocalEmu S3 |
| Lambda / S3 / ECS / RDS | **Partial**–**Working** pieces exist |
| Full E2E one smoke | **Backlog** |


## Quick start

Needs Docker + [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Optional: `psql`, `mysql`, `sshpass` for RDS / Transfer dataplane smokes.

cp .env.example .env   # first time; awsbox up also does this
./bin/awsbox console    # http://127.0.0.1:3000
aws --profile local s3 ls
./bin/awsbox down                 # keep profile
./bin/awsbox down --remove-profile

| What | Where |
| S3 (console buckets) | `http://127.0.0.1:8333` SeaweedFS |
| LocalEmu (IAM, Lambda, CFN, Transfer, RDS, …) | `http://127.0.0.1:4566` |
| Transfer SFTP (native) | `127.0.0.1:2222` (SSH public keys; `docs/transfer.md`) |
| Console | `http://127.0.0.1:3000` |
| Profile | `local` |

If profile `local` exists and isn’t awsbox-managed: `./bin/awsbox up --force`.

### WSL / Docker

Ports bind to `127.0.0.1` on WSL. Use Docker Desktop with WSL integration (or engine in WSL).


## Board & workflow

./bin/board-status.sh in-progress <n>
./bin/gap-check.sh <n>    # before done — Partial/UI stubs → Debt tickets
./bin/board-audit.sh
./bin/setup-github-board.sh

Gap rubric: [docs/gap-check.md](docs/gap-check.md) ·  
**Is this path tested?** → [docs/test-paths.md](docs/test-paths.md) · grid: [docs/smoke-matrix.md](docs/smoke-matrix.md).  
Closing a ticket that leaves a bridge, disabled console action, or happy-only smoke must open a **Debt:** follow-up the same day.


OpenSpec: `/opsx-propose` · `/opsx-apply` · `/opsx-explore`  
Console mocks: `design/awsbox-console/` · `./bin/od-design-run.sh --issue <n> "…"`
