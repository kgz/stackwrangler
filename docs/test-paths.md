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
| REST API import from OpenAPI + `aws_proxy` public route | happy | covered | `./bin/apigw-rest-smoke.sh` · [apigw-rest.md](apigw-rest.md) |
| REST REQUEST authorizer Allow → handler gets context | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer, no token → 401 | sad/authz | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer Deny → 401 (AWS 403) | sad/authz | thin | `./bin/apigw-rest-smoke.sh` · [#190](https://github.com/kgz/awsl/issues/190) |
| REST unknown route → 403 | sad/other | covered | `./bin/apigw-rest-smoke.sh` |
| REST custom domain + base-path mapping (control plane) | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST request via custom domain | happy | missing | [#191](https://github.com/kgz/awsl/issues/191) |
| VPC Lambda → host service by mapped hostname | happy | covered | `./bin/lambda-vpc-smoke.sh` · [lambda-vpc.md](lambda-vpc.md) |
| VPC Lambda → unmapped hostname → ENOTFOUND | sad/other | covered | `./bin/lambda-vpc-smoke.sh` |
| Non-VPC Lambda blocked from private hosts | sad/other | missing | [#187](https://github.com/kgz/awsl/issues/187) |
| Lambda role missing other actions | sad/authz | missing | extend `lambda-authz-smoke.sh` / [#150](https://github.com/kgz/awsl/issues/150) |
| ECS run-task + HTTP reachable | happy | covered | `./bin/ecs-smoke.sh` |
| **ECS task role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/ecs-authz-smoke.sh` |
| ECS secrets `valueFrom` (ASM JSON key + SSM) via execution role | happy | covered | `./bin/ecs-taskdef-smoke.sh` |
| **ECS execution role deny GetSecretValue → ResourceInitializationError** | sad/authz | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECS `networkMode: host` + portMappings listens on host | happy | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECS container create failure → STOPPED + stoppedReason | sad/other | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECS in-container SDK via 169.254 creds URI | sad/authz | thin | [#154](https://github.com/kgz/awsl/issues/154) |
| EC2 running + user-data file | happy | covered | `./bin/ec2-smoke.sh` |
| CFN/CDK/SAM deploy S3+Lambda write | happy | covered | `./bin/{cfn,cdk,sam}-smoke.sh` |
| Real AWS CFN S3+Lambda (same template) | happy | covered | `./bin/aws-parity-cfn-s3-lambda.sh` · [aws-parity-cfn.md](aws-parity-cfn.md) |
| Real AWS CFN empty Lambda role → AccessDenied | sad/authz | covered | `./bin/aws-parity-cfn-authz.sh` |
| Prowler aws scan (isolated, scoped unused-services) | happy | covered | `./bin/prowler-smoke.sh` · [prowler.md](prowler.md) |
| Prowler failing-API count ≤ baseline (ratchet) | sad/other | covered | `./bin/prowler-smoke.sh` |
| S3 Control GetPublicAccessBlock / ListAccessPoints (account) | happy | covered | `./bin/prowler-smoke.sh` spot-check |
| SQS send/receive/delete | happy | covered | `./bin/sqs-smoke.sh` |
| **SQS deny-user SendMessage → AccessDenied** | sad/authz | covered | `./bin/sqs-authz-smoke.sh` |
| SNS create/publish | happy | covered | `./bin/sns-smoke.sh` |
| SNS deny Publish | sad/authz | covered | `./bin/sns-authz-smoke.sh` |
| EventBridge put-events + rule | happy | covered | `./bin/events-smoke.sh` |
| EventBridge deny PutEvents | sad/authz | covered | `./bin/events-authz-smoke.sh` |
| DynamoDB put/get | happy | covered | `./bin/dynamodb-smoke.sh` |
| DynamoDB deny PutItem | sad/authz | covered | `./bin/dynamodb-authz-smoke.sh` |
| Step Functions Pass execution | happy | covered | `./bin/sfn-smoke.sh` |
| Step Functions deny StartExecution | sad/authz | covered | `./bin/sfn-authz-smoke.sh` |
| Secrets create/get | happy | covered | `./bin/secrets-smoke.sh` |
| Secrets deny GetSecretValue | sad/authz | covered | `./bin/secrets-authz-smoke.sh` |
| KMS encrypt/decrypt | happy | covered | `./bin/kms-smoke.sh` |
| KMS deny Decrypt | sad/authz | covered | `./bin/kms-authz-smoke.sh` |
| Kinesis put/get | happy | covered | `./bin/kinesis-smoke.sh` |
| Kinesis deny PutRecord | sad/authz | covered | `./bin/kinesis-authz-smoke.sh` |
| Logs deny PutLogEvents | sad/authz | covered | `./bin/logs-authz-smoke.sh` |
| API GW deny CreateApi | sad/authz | covered | `./bin/apigw-authz-smoke.sh` |
| EC2 deny RunInstances | sad/authz | covered | `./bin/ec2-authz-smoke.sh` |
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
| `awsl apply` synthetic VPC/subnet/SG ids + CIDRs | happy | covered | `./bin/mirror-smoke.sh` · [mirror.md](mirror.md) |
| `awsl mirror --out` inside the repo (not gitignored) | sad/other | covered | `./bin/mirror-smoke.sh` |
| `awsl apply` non-local endpoint | sad/other | covered | `./bin/mirror-smoke.sh` |
| Real-account `awsl mirror` read (Describe/List/Get only) | happy | missing | [#220](https://github.com/kgz/awsl/issues/220) |

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
