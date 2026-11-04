# Service status

Working / Partial / control-plane depth for the local stack. Product pitch and quick start live in the [root README](../README.md). Vision: [vision.md](vision.md). A VitePress docs site / Pages URL comes with #403 / #428.

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
| Console labels | **Working** | `STACKWRANGLER_LABELS` file kept outside the repo · [labels.md](labels.md) · `./smokes/account/labels-smoke.sh` |
| Dual S3 (SeaweedFS + LocalEmu) | **Documented split** | UI/`local` → `:8333`; Lambda/IaC → `:4566` · [s3-backends.md](s3-backends.md) · smoke `./smokes/s3/s3-dual-endpoint-smoke.sh` |
| IAM enforcement | **Partial** | resource policies `./smokes/security/resource-policy-smoke.sh` · cross-account [#233](https://github.com/kgz/awsl/issues/233) · workload roles [#144](https://github.com/kgz/awsl/issues/144) |
| Custom resource IDs + account in ARNs | **Working** | `_custom_id_` tag · [custom-ids.md](custom-ids.md) · `./smokes/account/custom-id-smoke.sh` |
| Local smokes / Playwright | **Local smokes** | No GHA e2e (by design) |


## Storage & objects

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| S3 general purpose | SeaweedFS objects + parity script | Buckets / objects / preview | **Working** (UI) · **Partial** (vs LocalEmu S3 for events) |
| S3 specialty / Access Points / Lens | — | Empty states | **Console chrome** · disabled controls [#355](https://github.com/kgz/awsl/issues/355) |
| Transfer Family | API + native SFTP (SSH keys) → S3; outbound connectors (`StartFileTransfer` → remote SFTP) | Servers list/detail · connectors: [#313](https://github.com/kgz/awsl/issues/313) | **Partial** (`docs/transfer.md`) · console user/key [#321](https://github.com/kgz/awsl/issues/321) · LOGICAL/IdP/authz [#322](https://github.com/kgz/awsl/issues/322) · retrieve/AS2 [#314](https://github.com/kgz/awsl/issues/314) |
| EFS / FSx / EBS | — | — | **Backlog** |

Smokes: `./smokes/s3/s3-parity.sh`, `./smokes/s3/s3-dual-endpoint-smoke.sh`, `./smokes/transfer/transfer-smoke.sh`, `./smokes/transfer/transfer-key-smoke.sh`, `./smokes/transfer/transfer-dataplane-smoke.sh`, `./smokes/transfer/transfer-authz-smoke.sh`, `./smokes/transfer/transfer-connector-smoke.sh`


## Compute & containers

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| Lambda | Docker invoke · VPC → host services ([lambda-vpc.md](lambda-vpc.md)) | Functions · Create · detail/Code (Monaco) | **Working** (authz depth → [#144](https://github.com/kgz/awsl/issues/144)) · VPC isolation **Partial** ([#187](https://github.com/kgz/awsl/issues/187)) · Create/detail UI [#351](https://github.com/kgz/awsl/issues/351) · list Actions [#357](https://github.com/kgz/awsl/issues/357) |
| EC2 | Docker instances · IMDSv2 instance-profile creds · user data · SSM `SendCommand` | Instances list | **Partial** · console depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECS | Docker tasks · secrets/`valueFrom` · host ports · EC2 container instances · desiredCount replacement · bridge ports → target groups · CodeDeploy blue/green · pull from ECR URI | Clusters / services / tasks | **Partial** · awsvpc ENI [#268](https://github.com/kgz/awsl/issues/268) · EC2 services [#207](https://github.com/kgz/awsl/issues/207) · bridge targets vs instance-IP health [#247](https://github.com/kgz/awsl/issues/247) · VPC NLB listeners [#203](https://github.com/kgz/awsl/issues/203) · depth [#146](https://github.com/kgz/awsl/issues/146) |
| ECR | create-repository · `get-login-password` · push/pull `127.0.0.1:5000/<repo>` · ECS task image `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` (needs `ecr:BatchGetImage`) | — | **Partial** · push the repositoryUri hostname [#218](https://github.com/kgz/awsl/issues/218) · Lambda image authz [#219](https://github.com/kgz/awsl/issues/219) · console [#217](https://github.com/kgz/awsl/issues/217) |
| Batch | compute env + job queue (moto) | — | **Control plane** · [batch-stubs.md](batch-stubs.md) · jobs [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| Elastic Beanstalk | create/describe application | — | **Control plane** · [batch-stubs.md](batch-stubs.md) · env [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| App Runner | list-* empty stub | — | **Control plane** · [batch-stubs.md](batch-stubs.md) · CreateService [#335](https://github.com/kgz/awsl/issues/335) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) |
| Auto Scaling / Application Auto Scaling | ASG create/set-desired/describe · register scalable target | — | **CLI + smoke** · real ECS hosts [#207](https://github.com/kgz/awsl/issues/207) · authz [#334](https://github.com/kgz/awsl/issues/334) · console [#337](https://github.com/kgz/awsl/issues/337) · [batch-stubs.md](batch-stubs.md) |
| EKS | — | — | **Backlog** |

Smokes: Lambda via console/CLI · `./smokes/lambda/lambda-vpc-smoke.sh` · `./smokes/compute/ecs-smoke.sh` · `./smokes/compute/ecs-authz-smoke.sh` · `./smokes/compute/ecs-taskdef-smoke.sh` · `./smokes/compute/ecs-host-creds-smoke.sh` · `./smokes/compute/ecs-ec2-smoke.sh` · `./smokes/compute/ec2-smoke.sh` · `./smokes/compute/ec2-imds-smoke.sh` · `./smokes/compute/ec2-authz-smoke.sh` · `./smokes/compute/ecr-smoke.sh` · `./smokes/networking/vpc-routing-smoke.sh` · `./smokes/networking/vpc-egress-smoke.sh` · `./smokes/networking/sg-enforcement-smoke.sh` · `./smokes/networking/vpce-private-dns-smoke.sh` · `./smokes/networking/elbv2-smoke.sh` · `./smokes/compute/autoscaling-smoke.sh` · `./smokes/compute/application-autoscaling-smoke.sh` · `./smokes/compute/batch-smoke.sh` · `./smokes/compute/elasticbeanstalk-smoke.sh` · `./smokes/compute/apprunner-smoke.sh`


## Networking

| Service | Status |
|---------|--------|
| Account mirror (`./bin/awsl mirror` / `apply`) | **Partial** — synthetic VPC/subnet/RT/SG + fixture tags · [mirror.md](mirror.md) · `./smokes/account/mirror-tags-smoke.sh` · real-account read [#220](https://github.com/kgz/awsl/issues/220) |
| VPC routes / peering / NAT / gateway endpoints | **Partial** · [vpc-routing.md](vpc-routing.md) · `./smokes/networking/vpc-egress-smoke.sh` · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC security groups | **Partial** · [sg-enforcement.md](sg-enforcement.md) · NLB client IP [#236](https://github.com/kgz/awsl/issues/236) · VPC Lambda [#237](https://github.com/kgz/awsl/issues/237) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC Interface endpoint private DNS | **Partial** · [vpce-private-dns.md](vpce-private-dns.md) · console [#146](https://github.com/kgz/awsl/issues/146) |
| VPC / AZ polish | **Backlog** |
| ALB / NLB / Classic ELB | **Partial** · [elbv2.md](elbv2.md) · console [#241](https://github.com/kgz/awsl/issues/241) · TLS ACM [#242](https://github.com/kgz/awsl/issues/242) · HTTP health [#243](https://github.com/kgz/awsl/issues/243) · ECS bridge smoke loopback forwarder [#247](https://github.com/kgz/awsl/issues/247) |
| Route 53 private zones | **Partial** — associated VPC only · `./smokes/networking/r53-private-smoke.sh` · [r53-private.md](r53-private.md) · console/Lambda [#245](https://github.com/kgz/awsl/issues/245) · API Gateway alias / public zones [#300](https://github.com/kgz/awsl/issues/300) |
| WAFv2 | **Partial** — create/associate API GW stage · rule eval **not** real edge WAF · [waf.md](waf.md) · console [#324](https://github.com/kgz/awsl/issues/324) · CFN [#325](https://github.com/kgz/awsl/issues/325) · edge eval [#326](https://github.com/kgz/awsl/issues/326) |
| CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./smokes/account/mirror-smoke.sh` · `./smokes/account/mirror-tags-smoke.sh` · `./smokes/networking/r53-private-smoke.sh` · `./smokes/networking/waf-smoke.sh` · `./smokes/networking/waf-authz-smoke.sh`
| Route 53 hosted zones + records | **Partial** — public A/alias/CNAME + dig in-emulator · `./smokes/networking/route53-smoke.sh` · [r53.md](r53.md) · console [#245](https://github.com/kgz/awsl/issues/245) · host dig / API GW alias [#300](https://github.com/kgz/awsl/issues/300) |
| WAFv2 / CloudFront | **Backlog** (likely control-plane first) |
| TGW / VPN / PrivateLink / Lattice | **Backlog** |

Smoke: `./smokes/account/mirror-smoke.sh` · `./smokes/account/mirror-tags-smoke.sh` · `./smokes/networking/route53-smoke.sh` · `./smokes/networking/r53-private-smoke.sh`


## Data stores

| RDS (Postgres) | Docker DB via `RDS_DOCKER_BACKEND` | Databases + `psql` hint | **Partial** · create/Aurora debt [#145](https://github.com/kgz/awsl/issues/145) |
| RDS (MySQL / Aurora MySQL) | Docker DB · writer/reader · `rds!` secret | Databases + `mysql` hint | **Partial** · failover [#225](https://github.com/kgz/awsl/issues/225) · console create [#145](https://github.com/kgz/awsl/issues/145) |
| DynamoDB | put/get · GSI query · scan filter · conditional writes · UpdateItem expressions · TransactWriteItems · TTL sweep · IAM on table/index ARNs | — | **Working** (CLI) · console [#174](https://github.com/kgz/awsl/issues/174) · `./smokes/data/dynamodb-depth-smoke.sh` · Batch/Transact table-scoped IAM [#306](https://github.com/kgz/awsl/issues/306) · index `aws:ResourceTag` [#307](https://github.com/kgz/awsl/issues/307) |
| ElastiCache / other DBs | — | — | **Backlog** |

Smoke: `./smokes/data/rds-smoke.sh` · sad: `./smokes/data/rds-authz-smoke.sh` (needs host `psql`) · MySQL/Aurora: `./smokes/data/rds-mysql-smoke.sh` (needs host `mysql`)


## Messaging & integration

| SQS | LocalEmu send/receive | — | **Working** (CLI) · console [#167](https://github.com/kgz/awsl/issues/167) · [sqs.md](sqs.md) |
| SNS | publish · MaximumMessageSize ≤1 MiB · SQS fan-out (queue policy / `SourceArn`; refuse `alias/aws/sqs` and a CMK without an SNS key grant) | — | **Working** (CLI) · console [#172](https://github.com/kgz/awsl/issues/172) · `./smokes/messaging/sns-sqs-fanout-smoke.sh` · `./smokes/messaging/sns-max-message-size-smoke.sh` |
| EventBridge | put-events + rule · scheduled `rate()` rule → Lambda (disable stops it; no invoke permission = no fire) | — | **Working** (CLI) · console [#173](https://github.com/kgz/awsl/issues/173) · [slice](../examples/serverless-v3-rest/slices/schedule/README.md) · cadence [#317](https://github.com/kgz/awsl/issues/317) |
| Step Functions | Pass state machine | — | **Working** (CLI) · console [#175](https://github.com/kgz/awsl/issues/175) |
| Kinesis | put/get records | — | **Working** (CLI) · console [#178](https://github.com/kgz/awsl/issues/178) |
| MSK / SES / AppSync | — | — | **Backlog** |

Smoke: `./smokes/messaging/sqs-smoke.sh` · `./smokes/messaging/sns-smoke.sh` · `./smokes/messaging/sns-max-message-size-smoke.sh` · `./smokes/messaging/sns-sqs-fanout-smoke.sh` · `./smokes/messaging/events-smoke.sh` · `./smokes/messaging/sfn-smoke.sh` · `./smokes/messaging/kinesis-smoke.sh` · `./smokes/data/dynamodb-depth-smoke.sh` · `./smokes/messaging/events-schedule-smoke.sh` · `./smokes/lambda/sqs-lambda-dlq-smoke.sh` (+ `*-authz-smoke.sh`)


## Security & identity

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| IAM users + AccessDenied lab | Enforced on LocalEmu S3 demo | Users + lab | **Partial** · resource policies `./smokes/security/resource-policy-smoke.sh` · workload roles [#144](https://github.com/kgz/awsl/issues/144) · Create/detail UI [#353](https://github.com/kgz/awsl/issues/353) · roles [#251](https://github.com/kgz/awsl/issues/251) |
| IAM OIDC / web identity | `AssumeRoleWithWebIdentity` checks a local JWKS; trust `StringEquals`/`StringLike` on `<issuer>:sub` and `:aud`. `repo:org/*` matches every repo in the org (risky). `iam:PassRole` is limited by `iam:PassedToService` | — | **CLI + smoke** · [oidc.md](oidc.md) · service-origin `kms:ViaService` / `aws:SourceArn` [#223](https://github.com/kgz/awsl/issues/223) |
| STS | Enabled | — | **Control plane** (polish backlog) |
| KMS | encrypt/decrypt · key policy on Encrypt/Decrypt/GenerateDataKey | — | **Partial** · key policy `./smokes/security/resource-policy-smoke.sh` · console [#177](https://github.com/kgz/awsl/issues/177) |
| Secrets Manager | create/get · resource policy on Get/Describe | — | **Partial** · resource policy `./smokes/security/resource-policy-smoke.sh` · console [#176](https://github.com/kgz/awsl/issues/176) |
| Multiple accounts | Key→account, isolated state, cross-account AssumeRole | — | **CLI + smoke** · [multi-account.md](multi-account.md) |
| ACM | request / import / describe / list · ARN on API custom domain + ALB HTTPS listener ([acm.md](acm.md)) | — ([#333](https://github.com/kgz/awsl/issues/333)) | **Partial** · TLS handshake [#242](https://github.com/kgz/awsl/issues/242) |
| Cognito / detection | — | — | **Backlog** |
| IAM Identity Center | — | — | **Backlog** |
| Prowler posture scan | Isolated CLI smoke vs LocalEmu | — | **Working** (scoped) · full catalog [#197](https://github.com/kgz/awsl/issues/197) · [prowler.md](prowler.md) |

Smoke: `./smokes/security/iam-access-denied.sh` · `./smokes/security/resource-policy-smoke.sh` · `./smokes/security/oidc-smoke.sh` · `./smokes/security/acm-smoke.sh` · `./smokes/security/prowler-smoke.sh` · `./smokes/security/multi-account-smoke.sh` · real AWS (~$0): `./smokes/parity/aws-parity-iam-denied.sh` ([aws-parity-agent-iam.md](aws-parity-agent-iam.md))  
CFN parity (local + real, short-lived): `./smokes/parity/aws-parity-cfn-s3-lambda.sh` · sad: `./smokes/parity/aws-parity-cfn-authz.sh` ([aws-parity-cfn.md](aws-parity-cfn.md))  
HF cheap parity (#296/#297/#190/#294/#230 VPCE; skipped WAF/R53/Transfer/…): `./smokes/parity/aws-parity-hf-cheap.sh` ([aws-parity-hf-cheap.md](aws-parity-hf-cheap.md))


## Observability & account

| Service | CLI / data | Console | Status |
|---------|------------|---------|--------|
| CloudWatch Logs | Log groups | Log groups | **Working** (basic) · sad [#169](https://github.com/kgz/awsl/issues/169) · create/detail UI [#352](https://github.com/kgz/awsl/issues/352) |
| API Gateway HTTP | APIs | HTTP APIs | **Partial** · sad [#170](https://github.com/kgz/awsl/issues/170) · detail UI [#354](https://github.com/kgz/awsl/issues/354) |
| API Gateway REST (v1) | OpenAPI import · `aws_proxy` · REQUEST authorizers · custom domain Host + base path · VPC_LINK → NLB · API keys + usage plans (`x-api-key`, throttle, quota; IAM `apigateway:POST/GET/DELETE` on `/apikeys`, `/usageplans`) ([apigw-rest.md](apigw-rest.md)) | — ([#189](https://github.com/kgz/awsl/issues/189), keys [#310](https://github.com/kgz/awsl/issues/310)) | **Partial** · ENI IP [#268](https://github.com/kgz/awsl/issues/268) · usage reporting [#309](https://github.com/kgz/awsl/issues/309) · IAM breadth [#311](https://github.com/kgz/awsl/issues/311) |
| Metrics / Alarms / SSM / CloudTrail / Orgs (empty reads) | Enabled for scanners (Prowler) | — | **Partial** (read-empty) · [#198](https://github.com/kgz/awsl/issues/198) · [prowler.md](prowler.md) |
| X-Ray / deeper observability | — | — | **Backlog** |

Smokes: `./smokes/apigw/apigw-smoke.sh` · `./smokes/apigw/apigw-authz-smoke.sh` · `./smokes/apigw/apigw-rest-smoke.sh` · `./smokes/apigw/apigw-nlb-ecs-smoke.sh` · `./smokes/apigw/apigw-usage-plan-smoke.sh` · `./smokes/apigw/apigw-proxy-body-smoke.sh`


## IaC & deploy

| Tool | Status |
|------|--------|
| Terraform S3+Lambda | **Working** (`examples/terraform/…`, local apply) |
| Terraform S3 backend + lock | **Working** ([terraform-awsbox.md](terraform-awsbox.md), `examples/terraform/awsbox-backend/`) |
| CloudFormation | **Partial** — failed create rolls back and delete-stack removes resources ([#212](https://github.com/kgz/awsl/issues/212)); in-place rollback / Snapshot [#228](https://github.com/kgz/awsl/issues/228); stacks UI; write path [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) · audit [#147](https://github.com/kgz/awsl/issues/147) |
| CDK / SAM samples | **Working** (smokes against local CFN) |
| Serverless Framework v3 | **Partial** — `examples/serverless-v3-rest` · [serverless-awsbox.md](serverless-awsbox.md) · authorizer http-event [#328](https://github.com/kgz/awsl/issues/328) · domain-manager [#329](https://github.com/kgz/awsl/issues/329) · sad smoke [#330](https://github.com/kgz/awsl/issues/330) |
| Pulumi / Ansible examples | **Backlog** |
| CodeDeploy | **CLI + smoke** — ECS blue/green + Lambda canary DG (control plane) · `./smokes/compute/codedeploy-smoke.sh` · slice `examples/serverless-v3-rest/slices/codedeploy/` · alias weight [#340](https://github.com/kgz/awsl/issues/340) · authz/console [#341](https://github.com/kgz/awsl/issues/341) |
| CodePipeline / Build / Artifact | **Backlog** |

Smokes: `./smokes/iac/iac-smoke.sh`, `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh`, `./smokes/iac/cfn-smoke.sh`, `./smokes/iac/cfn-lifecycle-smoke.sh`, `./smokes/iac/cdk-smoke.sh`, `./smokes/iac/sam-smoke.sh`, `./smokes/iac/serverless-v3-smoke.sh`, `./smokes/compute/codedeploy-smoke.sh`


## Org staging path (target)

VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS — epic [#90](https://github.com/kgz/awsl/issues/90) / path [#91](https://github.com/kgz/awsl/issues/91).

| Hop | Today |
|-----|--------|
| Transfer bytes | **Partial** native SSH-key SFTP → LocalEmu S3 |
| Lambda / S3 / ECS / RDS | **Partial**–**Working** pieces exist |
| Full E2E one smoke | **Backlog** |


