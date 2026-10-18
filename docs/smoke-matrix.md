# Smoke matrix — happy / sad / UI

Honest coverage. Update when adding or closing a smoke.  
**Sad path** = deliberate expected failure (authz, bad input, missing resource) that must exit 0 only when the failure is observed.

| Surface | Happy | Sad (authz / deny) | Sad (other) | Console e2e | Script |
|---------|-------|--------------------|-------------|-------------|--------|
| S3 SeaweedFS | yes | no (parity gaps noted) | partial (parity fail counts) | yes (playwright) | `s3-parity.sh`, `e2e.sh` |
| IAM AccessDenied lab | — | **yes** (deny user) | — | yes (lab) | `iam-access-denied.sh` |
| Lambda invoke/deploy | yes | **no** → [#144](https://github.com/kgz/awsl/issues/144) | state wait fails | thin | `lambda-smoke.sh`, `lambda-deploy-smoke.sh` |
| Logs | yes | no | — | thin | `logs-smoke.sh` |
| API GW | yes | no | — | thin | `apigw-smoke.sh` |
| CFN / CDK / SAM | yes | no | — | list/detail e2e | `cfn|cdk|sam-smoke.sh` |
| ECS | yes | **no** → [#144](https://github.com/kgz/awsl/issues/144) | task unreachable | list only | `ecs-smoke.sh` |
| EC2 | yes | no | user-data check | list only | `ec2-smoke.sh` |
| Transfer API | yes | no | — | list/create | `transfer-smoke.sh` |
| Transfer SFTP→S3 | yes (sidecar) | no | — | — | `transfer-dataplane-smoke.sh` · native [#141](https://github.com/kgz/awsl/issues/141) |
| RDS SQL | yes | no | missing psql/port | list/detail | `rds-smoke.sh` |

## Rule

New or “done” service smokes must have **≥1 happy** and **≥1 sad** (prefer authz). If sad is deferred, open/link a **Debt:** ticket before parent `done` (`./bin/gap-check.sh`).
