# Smoke matrix — happy / sad / UI

**Path lookup (preferred):** [test-paths.md](test-paths.md) — search by API action / scenario.

Honest coverage grid. Update when adding or closing a smoke.  
**Sad path** = deliberate expected failure that must exit 0 only when the failure is observed.

| Surface | Happy | Sad (authz / deny) | Sad (other) | Console e2e | Script |
|---------|-------|--------------------|-------------|-------------|--------|
| S3 SeaweedFS | yes | no (parity gaps) | dual-split | yes | `s3-parity.sh`, `s3-dual-endpoint-smoke.sh` |
| IAM AccessDenied lab | — | **yes** (deny user) | — | yes | `iam-access-denied.sh` |
| IAM OIDC + PassRole | yes (`environment:prod`, `repo:org/*`, events PassRole, tagged GetRole) | **yes** (feature ref, other org, bad aud, bad signature, states PassRole, untagged GetRole) | — | no | `oidc-smoke.sh` |
| Multi-account AssumeRole | yes (A assumes B) | **yes** (C, missing ExternalId, user without sts:AssumeRole, unknown condition) | A's bucket/role hidden from B | — | `multi-account-smoke.sh` |
| Real AWS IAM parity | — | **yes** (~$0) | — | — | `aws-parity-iam-denied.sh` |
| Real AWS CFN S3+Lambda | **yes** (parity) | **yes** (empty role) | teardown | — | `aws-parity-cfn-s3-lambda.sh`, `aws-parity-cfn-authz.sh` |
| Lambda VPC → host service | yes | no ([#187](https://github.com/kgz/awsl/issues/187)) | unmapped name | — | `lambda-vpc-smoke.sh` |
| Lambda invoke/deploy | yes | **yes** (`lambda-authz-smoke.sh`) | state wait | thin | `lambda-smoke.sh`, `lambda-deploy-smoke.sh`, `lambda-authz-smoke.sh` |
| Logs | yes | **yes** (`logs-authz-smoke.sh`) | — | thin | `logs-smoke.sh`, `logs-authz-smoke.sh` |
| API GW REST (v1) | yes | yes (no token / Deny / unknown route) | unmapped domain prefix; Deny 401≠403 [#190](https://github.com/kgz/awsl/issues/190) | no → [#189](https://github.com/kgz/awsl/issues/189) | `apigw-rest-smoke.sh` |
| API GW | yes | **yes** (`apigw-authz-smoke.sh`) | — | thin | `apigw-smoke.sh`, `apigw-authz-smoke.sh` |
| CFN / CDK / SAM | yes | **yes** (parity authz) | **yes** (rollback, failed update) | list/detail | `cfn\|cdk\|sam-smoke.sh`, `cfn-lifecycle-smoke.sh`, `aws-parity-cfn-authz.sh` |
| ECS | yes | **yes** (`ecs-authz-smoke.sh`, secrets deny in `ecs-taskdef-smoke.sh`) | task unreachable | list | `ecs-smoke.sh`, `ecs-authz-smoke.sh`, `ecs-taskdef-smoke.sh`, `ecs-host-creds-smoke.sh` |
| EC2 | yes | **yes** (`ec2-authz-smoke.sh`, instance-profile + `ssm:SendCommand` in `ec2-imds-smoke.sh`) | user-data | list | `ec2-smoke.sh`, `ec2-imds-smoke.sh`, `ec2-authz-smoke.sh` |
| ECR | yes | **yes** (execution role without `ecr:BatchGetImage`) | — | no → [#217](https://github.com/kgz/awsl/issues/217) | `ecr-smoke.sh` |
| VPC routes (private / peering / NAT) | yes | no | no default route; route removed | — | `vpc-routing-smoke.sh` |
| Security groups | yes (SG A, prefix list, CIDR) | **yes** (SG B refused; live revoke) | NLB client IP [#236](https://github.com/kgz/awsl/issues/236) | — | `sg-enforcement-smoke.sh` |
| VPCE private DNS (ecr/logs/ssm/sts/ecs) | yes (in-VPC resolve + call) | n/a (isolation is other-VPC) | other VPC does not get endpoint IP | — | `vpce-private-dns-smoke.sh` |
| SNS | yes | **yes** | — | no → [#172](https://github.com/kgz/awsl/issues/172) | `sns-smoke.sh`, `sns-authz-smoke.sh` |
| EventBridge | yes | **yes** | — | no → [#173](https://github.com/kgz/awsl/issues/173) | `events-smoke.sh`, `events-authz-smoke.sh` |
| DynamoDB | yes | **yes** | — | no → [#174](https://github.com/kgz/awsl/issues/174) | `dynamodb-smoke.sh`, `dynamodb-authz-smoke.sh` |
| Step Functions | yes | **yes** | — | no → [#175](https://github.com/kgz/awsl/issues/175) | `sfn-smoke.sh`, `sfn-authz-smoke.sh` |
| Secrets Manager | yes | **yes** | — | no → [#176](https://github.com/kgz/awsl/issues/176) | `secrets-smoke.sh`, `secrets-authz-smoke.sh` |
| KMS | yes | **yes** | — | no → [#177](https://github.com/kgz/awsl/issues/177) | `kms-smoke.sh`, `kms-authz-smoke.sh` |
| Resource policies (SM, KMS, S3) | yes (delegation allows) | **yes** (explicit deny / no key-policy delegation) | cross-account [#233](https://github.com/kgz/awsl/issues/233) | — | `resource-policy-smoke.sh` |
| Kinesis | yes | **yes** | — | no → [#178](https://github.com/kgz/awsl/issues/178) | `kinesis-smoke.sh`, `kinesis-authz-smoke.sh` |
| Transfer API | yes | **yes** (`transfer-authz-smoke.sh`) | — | list/create | `transfer-smoke.sh`, `transfer-authz-smoke.sh` |
| Transfer SFTP→S3 | yes (sidecar) | no → [#141](https://github.com/kgz/awsl/issues/141) | — | — | `transfer-dataplane-smoke.sh` |
| RDS SQL | yes | **yes** (wrong password) | missing psql | list/detail | `rds-smoke.sh`, `rds-authz-smoke.sh` |
| RDS MySQL / Aurora MySQL | yes | **yes** (wrong password) | reader read-only | list/detail · create [#145](https://github.com/kgz/awsl/issues/145) | `rds-mysql-smoke.sh` |
| SQS | yes | **yes** (deny SendMessage) | — | no → [#167](https://github.com/kgz/awsl/issues/167) | `sqs-smoke.sh`, `sqs-authz-smoke.sh` |
| SQS → Lambda mapping + DLQ | yes (message → Lambda → S3, deleted; redrive to DLQ) | **yes** (role without SQS read perms → CreateEventSourceMapping refused; emulator gap, script fails) | — | — | `sqs-lambda-dlq-smoke.sh` |
| Prowler | yes (scoped unused-services) | ratchet (failing API count) | S3 Control host | — | `prowler-smoke.sh` |
| Account mirror | yes (synthetic apply) | n/a (local apply) | in-repo write + non-local endpoint | — | `mirror-smoke.sh` |
| Terraform S3 backend + lock | yes (opt-in) | — | canary abort if real AWS STS succeeds | — | `terraform-backend-smoke.sh` (`AWSBOX_TERRAFORM_BACKEND_SMOKE=1`) |
| Account mirror tags | yes (tagged VPC/subnet/RT + TF data sources) | n/a (local apply) | — | — | `mirror-tags-smoke.sh` |
| Custom resource IDs | yes | n/a (same create APIs as service smokes) | bad `_custom_id_` | n/a | `custom-id-smoke.sh` |
| Console labels | yes (VPC id + NLB ARN glob) | — | missing file → no labels | list/detail | `labels-smoke.sh` |

## Rule

New or “done” service smokes must have **≥1 happy** and **≥1 sad** (prefer authz), and a row in [test-paths.md](test-paths.md). If sad is deferred, open/link a **Debt:** ticket before parent `done` (`./bin/gap-check.sh`).
