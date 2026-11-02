# Smoke matrix — happy / sad / UI

**Path lookup (preferred):** [test-paths.md](test-paths.md) — search by API action / scenario.

Honest coverage grid. Update when adding or closing a smoke.  
**Sad path** = deliberate expected failure that must exit 0 only when the failure is observed.

Scripts live in `smokes/<area>/` ([smokes.md](smokes.md)). `./bin/<name>.sh` still runs them. Script names in the table are the file name, not the directory.

| Surface | Happy | Sad (authz / deny) | Sad (other) | Console e2e | Script |
|---------|-------|--------------------|-------------|-------------|--------|
| S3 SeaweedFS | yes | no (parity gaps) | dual-split | yes | `s3-parity.sh`, `s3-dual-endpoint-smoke.sh` |
| IAM AccessDenied lab | — | **yes** (deny user) | — | yes | `iam-access-denied.sh` |
| IAM OIDC + PassRole | yes (`environment:prod`, `repo:org/*`, events PassRole, tagged GetRole) | **yes** (feature ref, other org, bad aud, bad signature, states PassRole, untagged GetRole) | — | no | `oidc-smoke.sh` |
| Multi-account AssumeRole | yes (A assumes B) | **yes** (C, missing ExternalId, user without sts:AssumeRole, unknown condition) | A's bucket/role hidden from B | — | `multi-account-smoke.sh` |
| Real AWS IAM parity | — | **yes** (~$0) | — | — | `aws-parity-iam-denied.sh` |
| Real AWS CFN S3+Lambda | **yes** (parity) | **yes** (empty role) | teardown | — | `aws-parity-cfn-s3-lambda.sh`, `aws-parity-cfn-authz.sh` |
| Real AWS HF cheap (#296/#297/#190/#294/#230 VPCE) | **yes** (focused) | **yes** (Deny 403, missing/disabled key) | schedule quiet after disable | — | `aws-parity-hf-cheap.sh` · skipped gaps [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md) |
| Lambda VPC → host service | yes | no ([#187](https://github.com/kgz/awsl/issues/187)) | unmapped name | — | `lambda-vpc-smoke.sh` |
| Lambda → Secrets Manager → OAuth token → external API | yes (+ per-stage secret isolation, env-var base URL) | **yes** (role without `GetSecretValue`: mock sees no requests) | wrong client secret → 401, no document posted | — | `lambda-secret-oauth-smoke.sh` |
| Lambda trust `aws:SourceAccount` | yes (same account; plain trust) | **yes** (other account refused) | — | — | `lambda-trust-condition-smoke.sh` |
| Lambda trust `aws:SourceArn` | yes (function ARN) | **yes** (other function ARN refused) | — | — | `lambda-trust-sourcearn-smoke.sh` |
| Lambda invoke/deploy | yes | **yes** (`lambda-authz-smoke.sh`) | state wait | thin | `lambda-smoke.sh`, `lambda-deploy-smoke.sh`, `lambda-authz-smoke.sh` |
| Logs | yes | **yes** (`logs-authz-smoke.sh`) | — | thin | `logs-smoke.sh`, `logs-authz-smoke.sh` |
| API GW REST (v1) | yes | yes (no token / Deny / unknown route) | unmapped domain prefix; Deny 401≠403 [#190](https://github.com/kgz/awsl/issues/190) | no → [#189](https://github.com/kgz/awsl/issues/189) | `apigw-rest-smoke.sh` |
| API GW REST HTTP_PROXY body | yes (curl `-d` form-urlencoded bytes unchanged) | — | re-encode regression [#364](https://github.com/kgz/awsl/issues/364) | — | `apigw-proxy-body-smoke.sh` |
| API GW REST API keys + usage plans | yes (Lambda-minted key 200; AUTHORIZER key source) | yes (no/unknown/disabled/revoked key 403; throttle + quota 429; role without `apigateway:POST` on `/apikeys` denied) | usage reporting / per-stage throttle [#309](https://github.com/kgz/awsl/issues/309); IAM breadth [#311](https://github.com/kgz/awsl/issues/311) | no → [#310](https://github.com/kgz/awsl/issues/310) | `apigw-usage-plan-smoke.sh` |
| API GW REST -> VPC link -> NLB -> ECS | **yes** (phase A VPC_LINK + NLB DNS; phase B; awsvpc ENI in subnet) | **yes** (no token / Deny / backend sees nothing / unhealthy target 5xx) | Deny 401≠403 [#190](https://github.com/kgz/awsl/issues/190) | no | `apigw-nlb-ecs-smoke.sh` |
| API GW REST (v1) | yes | yes (no token 401 / Deny 403 / unknown route) | unmapped domain prefix | no → [#189](https://github.com/kgz/awsl/issues/189) | `apigw-rest-smoke.sh` |
| API GW REST -> VPC link -> NLB -> ECS | **yes** (phase A VPC_LINK + NLB DNS; phase B; awsvpc ENI in subnet) | **yes** (no token / Deny 403 / backend sees nothing / unhealthy target 5xx) | — | no | `apigw-nlb-ecs-smoke.sh` |
| API GW | yes | **yes** (`apigw-authz-smoke.sh`) | — | thin | `apigw-smoke.sh`, `apigw-authz-smoke.sh` |
| CFN / CDK / SAM | yes | **yes** (parity authz) | **yes** (rollback, failed update) | list/detail | `cfn\|cdk\|sam-smoke.sh`, `cfn-lifecycle-smoke.sh`, `aws-parity-cfn-authz.sh` |
| Serverless Framework v3 | yes (deploy → route → redeploy → remove) | no → [#330](https://github.com/kgz/awsl/issues/330) | http authorizer CFN [#328](https://github.com/kgz/awsl/issues/328); domain-manager [#329](https://github.com/kgz/awsl/issues/329) | — | `serverless-v3-smoke.sh`, `serverless-v3-fixture-check.sh` |
| ECS | yes | **yes** (`ecs-authz-smoke.sh`, CreateService deny in `ecs-ec2-smoke.sh`, secrets deny in `ecs-taskdef-smoke.sh`) | task unreachable · bad CodeDeploy revision | list | `ecs-smoke.sh`, `ecs-authz-smoke.sh`, `ecs-taskdef-smoke.sh`, `ecs-host-creds-smoke.sh`, `ecs-ec2-smoke.sh` |
| CodeDeploy | yes (ECS BG + Lambda canary DG) | no → [#341](https://github.com/kgz/awsl/issues/341) | bad ECS revision → Failed · Lambda alias weight [#340](https://github.com/kgz/awsl/issues/340) | no → [#341](https://github.com/kgz/awsl/issues/341) | `codedeploy-smoke.sh` |
| EC2 | yes | **yes** (`ec2-authz-smoke.sh`, instance-profile + `ssm:SendCommand` in `ec2-imds-smoke.sh`) | user-data | list | `ec2-smoke.sh`, `ec2-imds-smoke.sh`, `ec2-authz-smoke.sh` |
| ECR | yes | **yes** (execution role without `ecr:BatchGetImage`) | — | no → [#217](https://github.com/kgz/awsl/issues/217) | `ecr-smoke.sh` |
| VPC routes (private / peering / NAT) | yes | no | no default route; route removed | — | `vpc-routing-smoke.sh` |
| VPC egress (Lambda + S3 GW endpoint + bridge attach) | yes (S3 via prefix list, peer, IGW restore, IGW attach/detach keeps `localemu-vpc-*` id [#386](https://github.com/kgz/awsl/issues/386), restart replay, ECS bridge on VPC net) | n/a (route fidelity) | public host blocked; S3 without GW endpoint | — | `vpc-egress-smoke.sh` |
| Egress via proxy (private ECS task, no default route) | yes (fetch via `HTTP_PROXY`, proxy log); emulator via `NO_PROXY` | **yes** (proxy allowlist refusal 403) | no direct route without proxy env | — | `egress-proxy-smoke.sh` |
| Egress via proxy (private ECS task, no default route) | yes (fetch via `HTTP_PROXY`, proxy log) | **yes** (proxy allowlist refusal 403) | no direct route without proxy env; non-root image blocked; emulator via `NO_PROXY` (fails: gap) | — | `egress-proxy-smoke.sh` |
| Egress via proxy (private ECS task, no default route) | yes (fetch via `HTTP_PROXY`, proxy log) | **yes** (proxy allowlist refusal 403) | no direct route without proxy; no default docker bridge (#271); emulator via `NO_PROXY` (fails: [#269](https://github.com/kgz/awsl/issues/269)) | — | `egress-proxy-smoke.sh` |
| Security groups | yes (SG A, prefix list, CIDR, VPC Lambda, Lambda→RDS) | **yes** (SG B refused; live revoke; Lambda egress; Lambda→RDS 5432) | NLB client IP [#236](https://github.com/kgz/awsl/issues/236) | — | `sg-enforcement-smoke.sh` |
| VPCE private DNS (ecr/logs/ssm/sts/ecs) | yes (in-VPC resolve + call) | n/a (isolation is other-VPC) | other VPC does not get endpoint IP | — | `vpce-private-dns-smoke.sh` |
| ELBv2 NLB/ALB | yes | **yes** (deny CreateLoadBalancer) | unhealthy target drops | no → [#241](https://github.com/kgz/awsl/issues/241) | `elbv2-smoke.sh` |
| SNS | yes | **yes** | — | no → [#172](https://github.com/kgz/awsl/issues/172) | `sns-smoke.sh`, `sns-authz-smoke.sh` |
| SNS MaximumMessageSize (≤1 MiB) | yes (CreateTopic/Set; 300 KiB–1 MiB → SQS raw; large-topic sqs/lambda/firehose) | **yes** (default >256 KiB; http/email/sms/application subscribe; Set with http sub) | ≤100 subs on large topics (patch; no 101-sub smoke) | no → [#172](https://github.com/kgz/awsl/issues/172) | `sns-max-message-size-smoke.sh` |
| SNS → SQS fan-out | yes (envelope, raw, filter; CMK with SNS grant) | **yes** (wrong/missing queue policy; `alias/aws/sqs` KMS; CMK without SNS grant; unsubscribe) | — | — | `sns-sqs-fanout-smoke.sh` |
| EventBridge | yes | **yes** | — | no → [#173](https://github.com/kgz/awsl/issues/173) | `events-smoke.sh`, `events-authz-smoke.sh` |
| EventBridge schedule → Lambda | yes (`rate(1 minute)` ≥2 invocations; none after disable-rule) | **yes** (rule without `lambda:InvokeFunction` for `events.amazonaws.com` never invokes) | — | no → [#173](https://github.com/kgz/awsl/issues/173) | `events-schedule-smoke.sh` |
| DynamoDB | yes | **yes** | — | no → [#174](https://github.com/kgz/awsl/issues/174) | `dynamodb-smoke.sh`, `dynamodb-authz-smoke.sh` |
| DynamoDB depth (GSI, conditions, UpdateItem, transactions, TTL) | yes (CFN slice `serverless-v3-rest/slices/ddb`) | **yes** (Allow on index ARN / table ARN only, Deny on index; Batch/Transact table-scoped [#306](https://github.com/kgz/awsl/issues/306)) | duplicate put, failed update condition, cancelled transaction; index `aws:ResourceTag` [#307](https://github.com/kgz/awsl/issues/307) | — | `dynamodb-depth-smoke.sh` |
| Step Functions | yes | **yes** | — | no → [#175](https://github.com/kgz/awsl/issues/175) | `sfn-smoke.sh`, `sfn-authz-smoke.sh` |
| Secrets Manager | yes | **yes** | — | no → [#176](https://github.com/kgz/awsl/issues/176) | `secrets-smoke.sh`, `secrets-authz-smoke.sh` |
| KMS | yes | **yes** | — | no → [#177](https://github.com/kgz/awsl/issues/177) | `kms-smoke.sh`, `kms-authz-smoke.sh` |
| Resource policies (SM, KMS, S3) | yes (delegation allows) | **yes** (explicit deny / no key-policy delegation) | cross-account [#233](https://github.com/kgz/awsl/issues/233) | — | `resource-policy-smoke.sh` |
| Kinesis | yes | **yes** | — | no → [#178](https://github.com/kgz/awsl/issues/178) | `kinesis-smoke.sh`, `kinesis-authz-smoke.sh` |
| Transfer API | yes | **yes** (`transfer-authz-smoke.sh`) | — | list/create | `transfer-smoke.sh`, `transfer-authz-smoke.sh` |
| Transfer SFTP→S3 | yes (sidecar) | no → [#141](https://github.com/kgz/awsl/issues/141) | — | — | `transfer-dataplane-smoke.sh` |
| Transfer outbound connector (S3 → remote SFTP) | yes (Lambda creates tenant connector; `start-file-transfer`; CloudWatch events) | **yes** (role without `s3:GetObject` / secret / `kms:Decrypt`, trust scoped to another account, Lambda without `iam:PassRole`) | wrong host key | no → [#313](https://github.com/kgz/awsl/issues/313) · retrieve [#314](https://github.com/kgz/awsl/issues/314) | `transfer-connector-smoke.sh` |
| Transfer SFTP→S3 (SSH keys) | yes (native) | **yes** (wrong key) | LOGICAL / IdP / SFTP-byte authz → [#322](https://github.com/kgz/awsl/issues/322) | create user + import key → [#321](https://github.com/kgz/awsl/issues/321) | `transfer-key-smoke.sh`, `transfer-dataplane-smoke.sh` |
| `awsbox up` SFTP host port (beta leftover) | yes (port free, or this project's `atmoz/sftp` container removed) | — | other project or other holder named; `up` stops before the emulator is left Created | — | `transfer-sftp-port-smoke.sh` |
| RDS SQL | yes | **yes** (wrong password) | missing psql | list/detail | `rds-smoke.sh`, `rds-authz-smoke.sh` |
| RDS MySQL / Aurora MySQL | yes | **yes** (wrong password) | reader read-only | list/detail · create [#145](https://github.com/kgz/awsl/issues/145) | `rds-mysql-smoke.sh` |
| SQS | yes | **yes** (deny SendMessage; MessageRetentionPeriod > 14d) | — | no → [#167](https://github.com/kgz/awsl/issues/167) | `sqs-smoke.sh`, `sqs-authz-smoke.sh` |
| SQS → Lambda mapping + DLQ | yes (message → Lambda → S3, deleted; redrive to DLQ) | **yes** (role without SQS; VT < timeout; MaximumConcurrency < 2) | — | — | `sqs-lambda-dlq-smoke.sh` (needs `boto3`) |
| Prowler | yes (scoped unused-services) | ratchet (failing API count) | S3 Control host | — | `prowler-smoke.sh` |
| Account mirror | yes (synthetic apply) | n/a (local apply) | in-repo write + non-local endpoint | — | `mirror-smoke.sh` |
| Terraform S3 backend + lock | yes (opt-in) | — | canary abort if real AWS STS succeeds | — | `terraform-backend-smoke.sh` (`AWSBOX_TERRAFORM_BACKEND_SMOKE=1`) |
| Account mirror tags | yes (tagged VPC/subnet/RT + TF data sources) | n/a (local apply) | — | — | `mirror-tags-smoke.sh` |
| Custom resource IDs | yes | n/a (same create APIs as service smokes) | bad `_custom_id_` | n/a | `custom-id-smoke.sh` |
| Console labels | yes (VPC id + NLB ARN glob) | — | missing file → no labels | list/detail | `labels-smoke.sh` |
| Route 53 public zones + records | yes (create, A / A-alias / CNAME, list, dig @127.0.0.1, private create, profile list) | **yes** (deny `route53:ListHostedZones`) | — | no → [#245](https://github.com/kgz/awsl/issues/245) | `route53-smoke.sh` |
| Route 53 private zones | yes (associated VPC CNAME connect, alias, A/AAAA, upstream forward, EC2 with #299 override) | **yes** (deny `route53:ListHostedZones`) | unassociated VPC NXDOMAIN | no → [#245](https://github.com/kgz/awsl/issues/245) | `r53-private-smoke.sh` |
| WAFv2 | yes (create + associate + get/list) | **yes** (`waf-authz-smoke.sh`) | rule eval not real → [#326](https://github.com/kgz/awsl/issues/326) | no → [#324](https://github.com/kgz/awsl/issues/324) | `waf-smoke.sh`, `waf-authz-smoke.sh` |
| ACM | yes (request/import/describe/list + API domain + ALB HTTPS ARN) | **yes** (deny `acm:RequestCertificate`) | TLS handshake [#242](https://github.com/kgz/awsl/issues/242) | no → [#333](https://github.com/kgz/awsl/issues/333) | `acm-smoke.sh` |
| Auto Scaling (ASG) | yes (create / set-desired 2 / describe) | no → [#334](https://github.com/kgz/awsl/issues/334) | real ECS host launch [#207](https://github.com/kgz/awsl/issues/207) | no → [#337](https://github.com/kgz/awsl/issues/337) | `autoscaling-smoke.sh` |
| Application Auto Scaling | yes (register/describe target) | no → [#334](https://github.com/kgz/awsl/issues/334) | — | no → [#337](https://github.com/kgz/awsl/issues/337) | `application-autoscaling-smoke.sh` |
| Batch | yes (CE + queue create/describe) | no → [#334](https://github.com/kgz/awsl/issues/334) | no job run → [#335](https://github.com/kgz/awsl/issues/335) | no → [#337](https://github.com/kgz/awsl/issues/337) | `batch-smoke.sh` |
| Elastic Beanstalk | yes (create/describe app) | no → [#334](https://github.com/kgz/awsl/issues/334) | no environment → [#335](https://github.com/kgz/awsl/issues/335) | no → [#337](https://github.com/kgz/awsl/issues/337) | `elasticbeanstalk-smoke.sh` |
| App Runner | yes (list-* empty stub) | no → [#334](https://github.com/kgz/awsl/issues/334) | CreateService → [#335](https://github.com/kgz/awsl/issues/335) | no → [#337](https://github.com/kgz/awsl/issues/337) | `apprunner-smoke.sh` |

## Rule

New or “done” service smokes must have **≥1 happy** and **≥1 sad** (prefer authz), and a row in [test-paths.md](test-paths.md). If sad is deferred, open/link a **Debt:** ticket before parent `done` (`./bin/gap-check.sh`).
