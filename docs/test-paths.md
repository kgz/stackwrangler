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
| OIDC `sub=repo:org/app:environment:prod` assumes tight role | happy | covered | `./bin/oidc-smoke.sh` · [oidc.md](oidc.md) |
| OIDC `sub=repo:org/*` assumes any repo in the org | happy | covered | `./bin/oidc-smoke.sh` |
| OIDC feature ref / other org / wrong aud / bad signature denied | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `iam:PassRole` when `iam:PassedToService=events.amazonaws.com` | happy | covered | `./bin/oidc-smoke.sh` |
| `iam:PassRole` to Step Functions denied by `PassedToService` | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `iam:GetRole` only when `aws:ResourceTag/env=prod` | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `kms:ViaService` / service-origin `aws:SourceArn` | sad/authz | missing | [#223](https://github.com/kgz/awsl/issues/223) |
| Access key → account (`AWSBOX_ACCOUNT_IDS`) | happy | covered | `./bin/multi-account-smoke.sh` · [multi-account.md](multi-account.md) |
| S3 bucket and IAM role in A hidden from B | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| `sts:AssumeRole` role in B trusts `arn:aws:iam::<A>:root` + `sts:ExternalId`; user in A assumes | happy | covered | `./bin/multi-account-smoke.sh` |
| AssumeRole without ExternalId / from account C / user missing `sts:AssumeRole` | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| Trust `StringEquals` `aws:PrincipalOrgID` does not allow | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| Cross-account resource policy Allow | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) |
| Real AWS: deny-user + empty role simulate PutObject | sad/authz | covered | `./bin/aws-parity-iam-denied.sh` (~$0; default creds) · [docs/aws-parity-agent-iam.md](aws-parity-agent-iam.md) |
| Lambda invoke hello (basic role) | happy | covered | `./bin/lambda-smoke.sh` |
| Lambda deploy zip | happy | covered | `./bin/lambda-deploy-smoke.sh` |
| **Lambda role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/lambda-authz-smoke.sh` |
| REST API import from OpenAPI + `aws_proxy` public route | happy | covered | `./bin/apigw-rest-smoke.sh` · [apigw-rest.md](apigw-rest.md) |
| REST REQUEST authorizer Allow → handler gets context | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer, no token → 401 | sad/authz | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer Deny → 401 (AWS 403) | sad/authz | thin | `./bin/apigw-rest-smoke.sh` · [#190](https://github.com/kgz/awsl/issues/190) |
| REST unknown route → 403 | sad/other | covered | `./bin/apigw-rest-smoke.sh` |
| REST custom domain + base-path mapping | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST request via custom domain (root mapping, local DNS) | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST request via custom domain named base path | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST custom domain unmapped prefix → 403 Forbidden | sad/other | covered | `./bin/apigw-rest-smoke.sh` |
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
| EC2 IMDSv2 instance-profile reads secret | happy | covered | `./bin/ec2-imds-smoke.sh` |
| EC2 instance-profile missing GetSecretValue → AccessDenied | sad/authz | covered | `./bin/ec2-imds-smoke.sh` |
| SSM SendCommand AWS-RunShellScript returns stdout | happy | covered | `./bin/ec2-imds-smoke.sh` |
| SSM SendCommand without ssm:SendCommand → AccessDenied | sad/authz | covered | `./bin/ec2-imds-smoke.sh` |
| CFN/CDK/SAM deploy S3+Lambda write | happy | covered | `./bin/{cfn,cdk,sam}-smoke.sh` |
| CFN failed create → `ROLLBACK_COMPLETE`, created resources removed, delete + recreate | sad/other | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN delete-stack removes resources; `DeletionPolicy: Retain` kept | happy | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN failed update → `UPDATE_ROLLBACK_COMPLETE` (not `UPDATE_COMPLETE`) | sad/other | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN failed update reverts in-place resource changes | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
| CFN `DeletionPolicy: Snapshot` | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
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
| Secret resource policy explicit deny beats Lambda-role IAM Allow (`GetSecretValue`, `DescribeSecret`) | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| KMS encrypt/decrypt | happy | covered | `./bin/kms-smoke.sh` |
| KMS deny Decrypt | sad/authz | covered | `./bin/kms-authz-smoke.sh` |
| KMS key policy delegates to IAM and role Encrypt/Decrypt/GenerateDataKey succeeds | happy | covered | `./bin/resource-policy-smoke.sh` |
| KMS key policy without IAM delegation denies a role IAM allows | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| KMS key policy explicit deny Encrypt | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| S3 bucket policy explicit deny GetObject/ListBucket | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Secrets Manager CMK GetSecretValue follows key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Secrets Manager CreateSecret/PutSecretValue with a CMK follows key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| SSM SecureString GetParameter/PutParameter follows CMK key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Cross-account resource policy (identity and resource must both allow) | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) · needs [#213](https://github.com/kgz/awsl/issues/213) |
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
| RDS MySQL instance + managed secret | happy | covered | `./bin/rds-mysql-smoke.sh` |
| **RDS MySQL wrong password → access denied** | sad/authz | covered | `./bin/rds-mysql-smoke.sh` |
| Aurora MySQL writer SQL via `rds!` secret | happy | covered | `./bin/rds-mysql-smoke.sh` |
| **Aurora MySQL reader rejects writes** | sad/other | covered | `./bin/rds-mysql-smoke.sh` |
| Aurora MySQL failover | sad/other | missing | [#225](https://github.com/kgz/awsl/issues/225) |
| Logs create/put/get | happy | covered | `./bin/logs-smoke.sh` |
| API GW HTTP create/invoke | happy | covered | `./bin/apigw-smoke.sh` |
| **Seaweed vs LocalEmu S3 are separate stores** | sad/other | covered | `./bin/s3-dual-endpoint-smoke.sh` · [s3-backends.md](s3-backends.md) |
| `awsl apply` synthetic VPC/subnet/SG ids + CIDRs | happy | covered | `./bin/mirror-smoke.sh` · [mirror.md](mirror.md) |
| `awsl mirror --out` inside the repo (not gitignored) | sad/other | covered | `./bin/mirror-smoke.sh` |
| `awsl apply` non-local endpoint | sad/other | covered | `./bin/mirror-smoke.sh` |
| Real-account `awsl mirror` read (Describe/List/Get only) | happy | missing | [#220](https://github.com/kgz/awsl/issues/220) |
| Create VPC/subnet/SG with `_custom_id_` + account id in OwnerId/STS/ARNs | happy | covered | `./bin/custom-id-smoke.sh` · [custom-ids.md](custom-ids.md) |
| Create route table, IGW, peering, instance, LB/TG suffix, REST/HTTP API, hosted zone, ECS cluster ARN with `_custom_id_` | happy | covered | `./bin/custom-id-smoke.sh` |
| `_custom_id_` value fails the id format check | sad/other | covered | `./bin/custom-id-smoke.sh` |

---

## How to run the suite (local)

```bash
./bin/awsbox up --force
./bin/e2e.sh                    # includes IAM deny + S3 parity + playwright subset
./bin/lambda-smoke.sh           # happy
./bin/lambda-authz-smoke.sh     # sad/authz
./bin/multi-account-smoke.sh    # key→account, AssumeRole, hidden bucket
./bin/transfer-dataplane-smoke.sh
./bin/rds-smoke.sh              # needs psql
./bin/rds-mysql-smoke.sh        # needs mysql
# …add others as you touch a surface
```

Wire new paths here **in the same PR** as the smoke. If deferred → Debt ticket + link in the Status column.
