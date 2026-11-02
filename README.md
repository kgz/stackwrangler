# stackwrangler

**Not affiliated with Amazon Web Services.** Independent open-source tooling to develop and test AWS-shaped stacks locally, then deploy to real AWS. Not an AWS product and not a hosted substitute for AWS.

One **local AWS-shaped account** — real APIs, console on localhost, IaC against profile `local`. Learn and stage without a cloud bill.

North star: [docs/vision.md](docs/vision.md) · Board: [Project #8](https://github.com/users/kgz/projects/8/views/1) · Release: [docs/versioning.md](docs/versioning.md) (`v0.0.1`) · [LICENSE](LICENSE) (MIT) · [THIRD_PARTY.md](THIRD_PARTY.md)

```bash
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
aws --profile local … # SeaweedFS S3 :8333 · LocalEmu :4566
```

Built on **LocalEmu** (not LocalStack Community — we need IAM enforcement) plus sidecars: **SeaweedFS** (console buckets), **distribution/registry** (ECR-shaped push/pull), **atmoz/sftp** (Transfer dataplane). Console buckets UI uses SeaweedFS; IaC/Lambda/S3 events use **LocalEmu S3**. Workflow: test on the local stack → deploy the same shape to real AWS.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **Working** | Data plane + CLI smoke + console for the happy path |
| **Partial** | Works with known gaps (dual backends, bridge, limited authz) |
| **Control plane** | `create-*` / `describe-*` OK; little/no real traffic |
| **CLI + smoke** | Script/example works; **no console** (or thin) |
| **Console chrome** | Nav / empty page only |
| **Sidecar** | Real bytes via stackwrangler container, not native service listen |
| **Backlog** | Ticketed, not started |
| **Local smokes** | Proven with `./bin/*-smoke.sh` (no GitHub Actions e2e) |


## Platform / core

| Area | Status | Notes |
|------|--------|--------|
| `./bin/stackwrangler up` + profile `local` | **Working** | Compose + managed AWS profile |
| Console shell (grey rose) | **Working** | Chrome from `design/awsbox-console` · S3 + built-service pages match mocks · unwired controls disabled → [#355](https://github.com/kgz/awsl/issues/355), [#357](https://github.com/kgz/awsl/issues/357) |
| Console labels | **Working** | `STACKWRANGLER_LABELS` file kept outside the repo · [docs/labels.md](docs/labels.md) · `./bin/labels-smoke.sh` |
| Dual S3 (SeaweedFS + LocalEmu) | **Documented split** | UI/`local` → `:8333`; Lambda/IaC → `:4566` · [docs/s3-backends.md](docs/s3-backends.md) · smoke `./bin/s3-dual-endpoint-smoke.sh` |
| IAM enforcement | **Partial** | resource policies `./bin/resource-policy-smoke.sh` · cross-account [#233](https://github.com/kgz/awsl/issues/233) · workload roles [#144](https://github.com/kgz/awsl/issues/144) |
| Custom resource IDs + account in ARNs | **Working** | `_custom_id_` tag · [docs/custom-ids.md](docs/custom-ids.md) · `./bin/custom-id-smoke.sh` |
| Local smokes / Playwright | **Local smokes** | No GHA e2e (by design) |


## Storage & objects

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| S3 general purpose | SeaweedFS objects + parity script | Buckets / objects / preview | **Working** (UI) · **Partial** (vs LocalEmu S3 for events) |
| S3 specialty / Access Points / Lens | — | Empty states | **Console chrome** · disabled controls [#355](https://github.com/kgz/awsl/issues/355) |
| Transfer Family | API + native SFTP (SSH keys) → S3; outbound connectors (`StartFileTransfer` → remote SFTP) | Servers list/detail · connectors: [#313](https://github.com/kgz/awsl/issues/313) | **Partial** (`docs/transfer.md`) · console user/key [#321](https://github.com/kgz/awsl/issues/321) · LOGICAL/IdP/authz [#322](https://github.com/kgz/awsl/issues/322) · retrieve/AS2 [#314](https://github.com/kgz/awsl/issues/314) |
| EFS / FSx / EBS | — | — | **Backlog** |

Smokes: `./bin/s3-parity.sh`, `./bin/s3-dual-endpoint-smoke.sh`, `./bin/transfer-smoke.sh`, `./bin/transfer-key-smoke.sh`, `./bin/transfer-dataplane-smoke.sh`, `./bin/transfer-authz-smoke.sh`, `./bin/transfer-connector-smoke.sh`


## Compute & containers

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| Lambda | Docker invoke · VPC → host services ([docs/lambda-vpc.md](docs/lambda-vpc.md)) | Functions · Create · detail/Code (Monaco) | **Working** (authz depth → [#144](https://github.com/kgz/awsl/issues/144)) · VPC isolation **Partial** ([#187](https://github.com/kgz/awsl/issues/187)) · Create/detail UI [#351](https://github.com/kgz/awsl/issues/351) · list Actions [#357](https://github.com/kgz/awsl/issues/357) |
| EC2 | Docker instances · IMDSv2 instance-profile creds · user data · SSM `SendCommand` | Instances list | **Partial** · console depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECS | Docker tasks · secrets/`valueFrom` · host ports · EC2 container instances · desiredCount replacement · bridge ports → target groups · CodeDeploy blue/green · pull from ECR URI | Clusters / services / tasks | **Partial** · awsvpc ENI [#268](https://github.com/kgz/awsl/issues/268) · EC2 services [#207](https://github.com/kgz/awsl/issues/207) · bridge targets vs instance-IP health [#247](https://github.com/kgz/awsl/issues/247) · VPC NLB listeners [#203](https://github.com/kgz/awsl/issues/203) · depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECR | create-repository · `get-login-password` · push/pull `127.0.0.1:5000/<repo>` · ECS task image `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` (needs `ecr:BatchGetImage`) | — | **Partial** · push the repositoryUri hostname [#218](https://github.com/kgz/awsl/issues/218) · Lambda image authz [#219](https://github.com/kgz/awsl/issues/219) · console [#217](https://github.com/kgz/awsl/issues/217) |
| Batch | compute env + job queue (moto) | — | **Control plane** · [docs/batch-stubs.md](docs/batch-stubs.md) · jobs [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| Elastic Beanstalk | create/describe application | — | **Control plane** · [docs/batch-stubs.md](docs/batch-stubs.md) · env [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| App Runner | list-* empty stub | — | **Control plane** · [docs/batch-stubs.md](docs/batch-stubs.md) · CreateService [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| Auto Scaling / Application Auto Scaling | ASG create/set-desired/describe · register scalable target | — | **CLI + smoke** · real ECS hosts [#207](https://github.com/kgz/awsl/issues/207) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) · [docs/batch-stubs.md](docs/batch-stubs.md) |
| EKS | — | — | **Backlog** |

Smokes: Lambda via console/CLI · `./bin/lambda-vpc-smoke.sh` · `./bin/ecs-smoke.sh` · `./bin/ecs-authz-smoke.sh` · `./bin/ecs-taskdef-smoke.sh` · `./bin/ecs-host-creds-smoke.sh` · `./bin/ecs-ec2-smoke.sh` · `./bin/ec2-smoke.sh` · `./bin/ec2-imds-smoke.sh` · `./bin/ec2-authz-smoke.sh` · `./bin/ecr-smoke.sh` · `./bin/vpc-routing-smoke.sh` · `./bin/vpc-egress-smoke.sh` · `./bin/sg-enforcement-smoke.sh` · `./bin/vpce-private-dns-smoke.sh` · `./bin/elbv2-smoke.sh` · `./bin/autoscaling-smoke.sh` · `./bin/application-autoscaling-smoke.sh` · `./bin/batch-smoke.sh` · `./bin/elasticbeanstalk-smoke.sh` · `./bin/apprunner-smoke.sh`


## Networking

| Service | Status |
|---------|--------|
| Account mirror (`./bin/awsl mirror` / `apply`) | **Partial** — synthetic VPC/subnet/RT/SG + fixture tags · [docs/mirror.md](docs/mirror.md) · `./bin/mirror-tags-smoke.sh` · real-account read [#220](https://github.com/kgz/awsl/issues/220) |
| VPC routes / peering / NAT / gateway endpoints | **Partial** · [docs/vpc-routing.md](docs/vpc-routing.md) · `./bin/vpc-egress-smoke.sh` · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC security groups | **Partial** · [docs/sg-enforcement.md](docs/sg-enforcement.md) · NLB client IP [#236](https://github.com/kgz/awsl/issues/236) · VPC Lambda [#237](https://github.com/kgz/awsl/issues/237) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC Interface endpoint private DNS | **Partial** · [docs/vpce-private-dns.md](docs/vpce-private-dns.md) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC / AZ polish | **Backlog** |
| ALB / NLB / Classic ELB | **Partial** · [docs/elbv2.md](docs/elbv2.md) · console [#241](https://github.com/kgz/awsl/issues/241) · TLS ACM [#242](https://github.com/kgz/awsl/issues/242) · HTTP health [#243](https://github.com/kgz/awsl/issues/243) · ECS bridge smoke loopback forwarder [#247](https://github.com/kgz/awsl/issues/247) |
| Route 53 private zones | **Partial** — associated VPC only · `./bin/r53-private-smoke.sh` · [docs/r53-private.md](docs/r53-private.md) · console/Lambda [#245](https://github.com/kgz/awsl/issues/245) · API Gateway alias / public zones [#300](https://github.com/kgz/awsl/issues/300) |
| WAFv2 | **Partial** — create/associate API GW stage · rule eval **not** real edge WAF · [docs/waf.md](docs/waf.md) · console [#324](https://github.com/kgz/awsl/issues/324) · CFN [#325](https://github.com/kgz/awsl/issues/325) · edge eval [#326](https://github.com/kgz/awsl/issues/326) |
| Network Firewall | **Partial** — rule group + firewall policy control plane · no packet filter · [docs/network-firewall.md](docs/network-firewall.md) · console [#438](https://github.com/kgz/stackwrangler/issues/438) · filter [#441](https://github.com/kgz/stackwrangler/issues/441) · authz [#440](https://github.com/kgz/stackwrangler/issues/440) |
| Firewall Manager | **Partial** — Put/Get/List policy stub · no org enforcement · [docs/network-firewall.md](docs/network-firewall.md) · console [#439](https://github.com/kgz/stackwrangler/issues/439) · enforce [#442](https://github.com/kgz/stackwrangler/issues/442) · authz [#440](https://github.com/kgz/stackwrangler/issues/440) |
| CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./bin/mirror-smoke.sh` · `./bin/mirror-tags-smoke.sh` · `./bin/r53-private-smoke.sh` · `./bin/waf-smoke.sh` · `./bin/waf-authz-smoke.sh` · `./bin/network-firewall-fms-smoke.sh`
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
| SNS | publish · MaximumMessageSize ≤1 MiB · SQS fan-out (queue policy / `SourceArn`; refuse `alias/aws/sqs` and a CMK without an SNS key grant) | — | **Working** (CLI) · console [#172](https://github.com/kgz/awsl/issues/172) · `./bin/sns-sqs-fanout-smoke.sh` · `./bin/sns-max-message-size-smoke.sh` |
| EventBridge | put-events + rule · scheduled `rate()` rule → Lambda (disable stops it; no invoke permission = no fire) | — | **Working** (CLI) · console [#173](https://github.com/kgz/awsl/issues/173) · [slice](examples/serverless-v3-rest/slices/schedule/README.md) · cadence [#317](https://github.com/kgz/awsl/issues/317) |
| Step Functions | Pass state machine | — | **Working** (CLI) · console [#175](https://github.com/kgz/awsl/issues/175) |
| Kinesis | put/get records | — | **Working** (CLI) · console [#178](https://github.com/kgz/awsl/issues/178) |
| MSK / SES / AppSync | — | — | **Backlog** |

Smoke: `./bin/sqs-smoke.sh` · `./bin/sns-smoke.sh` · `./bin/sns-max-message-size-smoke.sh` · `./bin/sns-sqs-fanout-smoke.sh` · `./bin/events-smoke.sh` · `./bin/sfn-smoke.sh` · `./bin/kinesis-smoke.sh` · `./bin/dynamodb-depth-smoke.sh` · `./bin/events-schedule-smoke.sh` · `./bin/sqs-lambda-dlq-smoke.sh` (+ `*-authz-smoke.sh`)


## Security & identity

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| IAM users + AccessDenied lab | Enforced on LocalEmu S3 demo | Users + lab | **Partial** · resource policies `./bin/resource-policy-smoke.sh` · workload roles [#144](https://github.com/kgz/awsl/issues/144) · Create/detail UI [#353](https://github.com/kgz/awsl/issues/353) · roles [#251](https://github.com/kgz/awsl/issues/251) |
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
HF cheap parity (#296/#297/#190/#294/#230 VPCE; skipped WAF/R53/Transfer/…): `./bin/aws-parity-hf-cheap.sh` ([docs/aws-parity-hf-cheap.md](docs/aws-parity-hf-cheap.md))


## Observability & account

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| CloudWatch Logs | Log groups | Log groups | **Working** (basic) · sad [#169](https://github.com/kgz/awsl/issues/169) · create/detail UI [#352](https://github.com/kgz/awsl/issues/352) |
| API Gateway HTTP | APIs | HTTP APIs | **Partial** · sad [#170](https://github.com/kgz/awsl/issues/170) · detail UI [#354](https://github.com/kgz/awsl/issues/354) |
| API Gateway REST (v1) | OpenAPI import · `aws_proxy` · REQUEST authorizers · custom domain Host + base path · VPC_LINK → NLB · API keys + usage plans (`x-api-key`, throttle, quota; IAM `apigateway:POST/GET/DELETE` on `/apikeys`, `/usageplans`) ([docs/apigw-rest.md](docs/apigw-rest.md)) | — ([#189](https://github.com/kgz/awsl/issues/189), keys [#310](https://github.com/kgz/awsl/issues/310)) | **Partial** · ENI IP [#268](https://github.com/kgz/awsl/issues/268) · usage reporting [#309](https://github.com/kgz/awsl/issues/309) · IAM breadth [#311](https://github.com/kgz/awsl/issues/311) |
| Metrics / Alarms / SSM / CloudTrail / Orgs (empty reads) | Enabled for scanners (Prowler) | — | **Partial** (read-empty) · [#198](https://github.com/kgz/awsl/issues/198) · [docs/prowler.md](docs/prowler.md) |
| X-Ray / deeper observability | — | — | **Backlog** |

Smokes: `./bin/apigw-smoke.sh` · `./bin/apigw-authz-smoke.sh` · `./bin/apigw-rest-smoke.sh` · `./bin/apigw-nlb-ecs-smoke.sh` · `./bin/apigw-usage-plan-smoke.sh` · `./bin/apigw-proxy-body-smoke.sh`


## IaC & deploy

| Tool | Status |
|------|--------|
| Terraform S3+Lambda | **Working** (`examples/terraform/…`, local apply) |
| Terraform S3 backend + lock | **Working** ([docs/terraform-awsbox.md](docs/terraform-awsbox.md), `examples/terraform/awsbox-backend/`) |
| CloudFormation | **Partial** — failed create rolls back and delete-stack removes resources ([#212](https://github.com/kgz/awsl/issues/212)); in-place rollback / Snapshot [#228](https://github.com/kgz/awsl/issues/228); stacks UI; write path [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) · audit [#147](https://github.com/kgz/awsl/issues/147) |
| CDK / SAM samples | **Working** (smokes against local CFN) |
| Serverless Framework v3 | **Partial** — `examples/serverless-v3-rest` · [docs/serverless-awsbox.md](docs/serverless-awsbox.md) · authorizer http-event [#328](https://github.com/kgz/awsl/issues/328) · domain-manager [#329](https://github.com/kgz/awsl/issues/329) · sad smoke [#330](https://github.com/kgz/awsl/issues/330) |
| Pulumi / Ansible examples | **Backlog** |
| CodeDeploy | **CLI + smoke** — ECS blue/green + Lambda canary DG (control plane) · `./bin/codedeploy-smoke.sh` · slice `examples/serverless-v3-rest/slices/codedeploy/` · alias weight [#340](https://github.com/kgz/awsl/issues/340) · authz/console [#341](https://github.com/kgz/awsl/issues/341) |
| CodePipeline / Build / Artifact | **Backlog** |

Smokes: `./bin/iac-smoke.sh`, `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh`, `./bin/cfn-smoke.sh`, `./bin/cfn-lifecycle-smoke.sh`, `./bin/cdk-smoke.sh`, `./bin/sam-smoke.sh`, `./bin/serverless-v3-smoke.sh`, `./bin/codedeploy-smoke.sh`


## Org staging path (target)

VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS — epic [#90](https://github.com/kgz/awsl/issues/90) / path [#91](https://github.com/kgz/awsl/issues/91).

| Hop | Today |
|-----|--------|
| Transfer bytes | **Partial** native SSH-key SFTP → LocalEmu S3 |
| Lambda / S3 / ECS / RDS | **Partial**–**Working** pieces exist |
| Full E2E one smoke | **Backlog** |


## Quick start

Needs Docker + [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Optional: `psql`, `mysql`, `sshpass` for RDS / Transfer dataplane smokes.

cp .env.example .env   # first time; stackwrangler up also does this
./bin/stackwrangler console    # http://127.0.0.1:3000
aws --profile local s3 ls
./bin/stackwrangler down                 # keep profile
./bin/stackwrangler down --remove-profile

| What | Where |
| S3 (console buckets) | `http://127.0.0.1:8333` SeaweedFS |
| LocalEmu (IAM, Lambda, CFN, Transfer, RDS, …) | `http://127.0.0.1:4566` |
| Transfer SFTP (native) | `127.0.0.1:2222` (SSH public keys; `docs/transfer.md`) |
| Console | `http://127.0.0.1:3000` |
| Profile | `local` |

If profile `local` exists and isn’t stackwrangler-managed: `./bin/stackwrangler up --force`.

Coming from `beta/full-flow-v1`, `./bin/stackwrangler up` removes this checkout's leftover `sftp` container (compose project of this directory, image `atmoz/sftp`, often `awsl-sftp-1`) when it still holds `127.0.0.1:2222`. Any other holder is named and `up` stops before Compose leaves the emulator `Created`. Set `STACKWRANGLER_SFTP_HOST_PORT` to keep that process. Details: `docs/transfer.md`.

### WSL / Docker

Ports bind to `127.0.0.1` on WSL. Use Docker Desktop with WSL integration (or engine in WSL).


## Board & workflow

```bash
./bin/board-status.sh designing <n>     # web UI — Open Design first
./bin/board-status.sh in-progress <n>
./bin/gap-check.sh <n>    # before done — Partial/UI stubs → Debt tickets
./bin/board-audit.sh
./bin/setup-github-board.sh

Lifecycle: **Backlog** → **Ready** → **Designing** → **In progress** → **In review** → **Done**.

Gap rubric: [docs/gap-check.md](docs/gap-check.md) ·  
**Is this path tested?** → [docs/test-paths.md](docs/test-paths.md) · grid: [docs/smoke-matrix.md](docs/smoke-matrix.md).  
New smokes: [docs/smokes.md](docs/smokes.md) (`smokes/<area>/`; `./bin/…` wrappers still work).  
Closing a ticket that leaves a bridge, disabled console action, or happy-only smoke must open a **Debt:** follow-up the same day.

OpenSpec: `/opsx-propose` · `/opsx-apply` · `/opsx-explore`  
Console mocks: `design/awsbox-console/` · theme `design/awsbox/` · `./bin/od-design-run.sh --issue <n> "…"` (web-clone for real AWS screens). Full Create/detail UI tracker: [#350](https://github.com/kgz/awsl/issues/350).
