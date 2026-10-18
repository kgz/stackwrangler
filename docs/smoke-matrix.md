# Smoke matrix — happy / sad / UI

**Path lookup (preferred):** [test-paths.md](test-paths.md) — search by API action / scenario.

Honest coverage grid. Update when adding or closing a smoke.  
**Sad path** = deliberate expected failure that must exit 0 only when the failure is observed.

| Surface | Happy | Sad (authz / deny) | Sad (other) | Console e2e | Script |
|---------|-------|--------------------|-------------|-------------|--------|
| S3 SeaweedFS | yes | no (parity gaps) | dual-split | yes | `s3-parity.sh`, `s3-dual-endpoint-smoke.sh` |
| IAM AccessDenied lab | — | **yes** (deny user) | — | yes | `iam-access-denied.sh` |
| Real AWS IAM parity | — | **yes** (~$0) | — | — | `aws-parity-iam-denied.sh` |
| Real AWS CFN S3+Lambda | **yes** (parity) | **yes** (empty role) | teardown | — | `aws-parity-cfn-s3-lambda.sh`, `aws-parity-cfn-authz.sh` |
| Lambda invoke/deploy | yes | **yes** (`lambda-authz-smoke.sh`) | state wait | thin | `lambda-smoke.sh`, `lambda-deploy-smoke.sh`, `lambda-authz-smoke.sh` |
| Logs | yes | no → [#150](https://github.com/kgz/awsl/issues/150) | — | thin | `logs-smoke.sh` |
| API GW | yes | no → [#150](https://github.com/kgz/awsl/issues/150) | — | thin | `apigw-smoke.sh` |
| CFN / CDK / SAM | yes | no → [#150](https://github.com/kgz/awsl/issues/150) | — | list/detail | `cfn\|cdk\|sam-smoke.sh` |
| ECS | yes | **yes** (`ecs-authz-smoke.sh`) | task unreachable | list | `ecs-smoke.sh`, `ecs-authz-smoke.sh` |
| EC2 | yes | no → [#150](https://github.com/kgz/awsl/issues/150) | user-data | list | `ec2-smoke.sh` |
| Transfer API | yes | **yes** (`transfer-authz-smoke.sh`) | — | list/create | `transfer-smoke.sh`, `transfer-authz-smoke.sh` |
| Transfer SFTP→S3 | yes (sidecar) | no → [#141](https://github.com/kgz/awsl/issues/141) | — | — | `transfer-dataplane-smoke.sh` |
| RDS SQL | yes | **yes** (wrong password) | missing psql | list/detail | `rds-smoke.sh`, `rds-authz-smoke.sh` |
| SQS | yes | **yes** (deny SendMessage) | — | no → [#167](https://github.com/kgz/awsl/issues/167) | `sqs-smoke.sh`, `sqs-authz-smoke.sh` |

## Rule

New or “done” service smokes must have **≥1 happy** and **≥1 sad** (prefer authz), and a row in [test-paths.md](test-paths.md). If sad is deferred, open/link a **Debt:** ticket before parent `done` (`./bin/gap-check.sh`).
