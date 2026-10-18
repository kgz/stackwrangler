# Test path rubric (lookup)

**Quick answer:** search this page for the path (e.g. `s3:PutObject`, `AccessDenied`, `SFTP put`).  
If it’s not listed, it is **untested** — add a smoke + row, or a Debt ticket.

Companion tables: [smoke-matrix.md](smoke-matrix.md) (yes/no grid) · [gap-check.md](gap-check.md) (before `done`).

## Legend

| Kind | Meaning |
|------|---------|
| **happy** | Expected success |
| **sad/authz** | Deliberate deny / missing permission |
| **sad/other** | Missing resource, bad state, tool missing |
| **ui** | Playwright / console interaction |

| Status | Meaning |
|--------|---------|
| covered | Script asserts the outcome |
| thin | Partial / incidental only |
| missing | No automated check |

---

## Path → coverage

| Path / scenario | Kind | Status | How |
|-----------------|------|--------|-----|
| `aws s3` mb/ls/cp/rm (SeaweedFS profile) | happy | covered | `./bin/s3-parity.sh` |
| S3 console buckets/objects | ui | covered | `cd console && yarn test:e2e` / `./bin/e2e.sh` |
| IAM user + deny `s3:ListAllMyBuckets` → AccessDenied | sad/authz | covered | `./bin/iam-access-denied.sh` + IAM console lab |
| Real AWS: deny-user + empty role simulate PutObject | sad/authz | covered | `./bin/aws-parity-iam-denied.sh` (~$0; default creds) · [docs/aws-parity-agent-iam.md](aws-parity-agent-iam.md) |
| Lambda invoke hello (basic role) | happy | covered | `./bin/lambda-smoke.sh` |
| Lambda deploy zip | happy | covered | `./bin/lambda-deploy-smoke.sh` |
| **Lambda role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/lambda-authz-smoke.sh` |
| Lambda role missing other actions | sad/authz | missing | extend `lambda-authz-smoke.sh` / [#150](https://github.com/kgz/awsl/issues/150) |
| ECS run-task + HTTP reachable | happy | covered | `./bin/ecs-smoke.sh` |
| **ECS task role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/ecs-authz-smoke.sh` |
| ECS in-container SDK via 169.254 creds URI | sad/authz | thin | [#154](https://github.com/kgz/awsl/issues/154) |
| EC2 running + user-data file | happy | covered | `./bin/ec2-smoke.sh` |
| CFN/CDK/SAM deploy S3+Lambda write | happy | covered | `./bin/{cfn,cdk,sam}-smoke.sh` |
| Real AWS CFN S3+Lambda (same template) | happy | covered | `./bin/aws-parity-cfn-s3-lambda.sh` · [aws-parity-cfn.md](aws-parity-cfn.md) |
| Real AWS CFN empty Lambda role → AccessDenied | sad/authz | covered | `./bin/aws-parity-cfn-authz.sh` |
| SQS send/receive/delete | happy | covered | `./bin/sqs-smoke.sh` |
| **SQS deny-user SendMessage → AccessDenied** | sad/authz | covered | `./bin/sqs-authz-smoke.sh` |
| CFN console list/detail tabs | ui | covered | `console/e2e/cfn-stacks.spec.ts` |
| CFN Create/Update in console | ui | missing | [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) |
| Transfer create-server / create-user API | happy | covered | `./bin/transfer-smoke.sh` |
| SFTP put via sidecar → LocalEmu S3 | happy | covered | `./bin/transfer-dataplane-smoke.sh` |
| Transfer user SSH key auth (native) | happy | missing | [#141](https://github.com/kgz/awsl/issues/141) |
| **Transfer empty role → simulate PutObject deny** | sad/authz | covered | `./bin/transfer-authz-smoke.sh` |
| Transfer under-permissioned role (SFTP bytes) | sad/authz | missing | [#141](https://github.com/kgz/awsl/issues/141) |
| RDS Postgres SQL round-trip | happy | covered | `./bin/rds-smoke.sh` |
| **RDS wrong password → auth denied** | sad/authz | covered | `./bin/rds-authz-smoke.sh` |
| RDS IAM DB auth | sad/authz | missing | [#145](https://github.com/kgz/awsl/issues/145) |
| Logs create/put/get | happy | covered | `./bin/logs-smoke.sh` |
| API GW HTTP create/invoke | happy | covered | `./bin/apigw-smoke.sh` |
| **Seaweed vs LocalEmu S3 are separate stores** | sad/other | covered | `./bin/s3-dual-endpoint-smoke.sh` · [s3-backends.md](s3-backends.md) |

---

## How to run the suite (local)

```bash
./bin/awsbox up --force
./bin/e2e.sh                    # includes IAM deny + S3 parity + playwright subset
./bin/lambda-smoke.sh           # happy
./bin/lambda-authz-smoke.sh     # sad/authz
./bin/transfer-dataplane-smoke.sh
./bin/rds-smoke.sh              # needs psql
# …add others as you touch a surface
```

Wire new paths here **in the same PR** as the smoke. If deferred → Debt ticket + link in the Status column.
