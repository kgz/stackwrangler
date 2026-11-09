# Interactions catalog

Honest map of **what talks to what** in the local account. Coverage truth for scripts stays in [smoke-matrix](https://github.com/kgz/stackwrangler/blob/main/docs/smoke-matrix.md) and [test-paths](https://github.com/kgz/stackwrangler/blob/main/docs/test-paths.md). This catalog is the short narrative layer for humans and agents.

**Status:** `shipped` · `partial` · `gap` · `not-valid`

| Status | Meaning |
|--------|---------|
| shipped | Happy path smoked; claims match behaviour |
| partial | Works with known gaps (issue links on the page) |
| gap | Expected path not proven — do not market as ready |
| not-valid | We do **not** claim this path |

One edge per page. Rows not listed yet are **not catalogued** (still may have a smoke). How to add pages: [docs-catalog.md](https://github.com/kgz/stackwrangler/blob/main/docs/docs-catalog.md).

Follow-ups: architecture map shot [#483](https://github.com/kgz/stackwrangler/issues/483) · Kinesis/SFN/DynamoDB pages [#484](https://github.com/kgz/stackwrangler/issues/484) · Serverless deploy page [#485](https://github.com/kgz/stackwrangler/issues/485) · SQS→Lambda ESM detail [#486](https://github.com/kgz/stackwrangler/issues/486).

| Edge | Status | Smoke | UI shot | Page |
|------|--------|-------|---------|------|
| SNS → SQS fan-out | shipped | `sns-sqs-fanout-smoke.sh` | — | [sns-to-sqs](./sns-to-sqs) |
| EventBridge schedule → Lambda | shipped | `events-schedule-smoke.sh` | — | [events-to-lambda](./events-to-lambda) |
| EventBridge Scheduler → SQS | shipped | `scheduler-smoke.sh` | — | [scheduler-to-sqs](./scheduler-to-sqs) |
| API GW REST → VPC link → NLB → ECS | partial | `apigw-nlb-ecs-smoke.sh` | — | [apigw-nlb-ecs](./apigw-nlb-ecs) |
| Lambda → Secrets → OAuth HTTP | shipped | `lambda-secret-oauth-smoke.sh` | — | [lambda-secrets-http](./lambda-secrets-http) |
| Transfer SFTP → S3 | partial | `transfer-dataplane-smoke.sh`, `transfer-key-smoke.sh` | — | [transfer-sftp-s3](./transfer-sftp-s3) |
| Dual S3 (SeaweedFS + LocalEmu) | partial | `s3-dual-endpoint-smoke.sh` | [home-s3-buckets](/assets/console/home-s3-buckets.png) | [dual-s3](./dual-s3) |
| IAM AccessDenied lab | shipped | `iam-access-denied.sh` | — | [iam-deny](./iam-deny) |
| IAM role path in resource ARN | shipped | `iam-role-path-arn-smoke.sh` | — | [iam-role-path](./iam-role-path) |
| S3 SSE-KMS ViaService / SourceArn | shipped | `service-origin-condition-keys-smoke.sh` | — | [s3-kms-via-service](./s3-kms-via-service) |
| Secrets Manager CMK ViaService / ResourceAliases | shipped | `kms-via-secrets-aliases-smoke.sh` | — | [secrets-kms-via-aliases](./secrets-kms-via-aliases) |
| Lambda VPC → host service | working | `lambda-vpc-smoke.sh` | non-VPC mapped name | [lambda-vpc-host](./lambda-vpc-host) |
| SQS → Lambda (event source) | partial | see page | — | [sqs-to-lambda](./sqs-to-lambda) |
| ECS task → ECR image pull | partial | `ecr-smoke.sh` | — | [ecs-ecr-pull](./ecs-ecr-pull) |
| Lambda ImageUri → ECR pull | shipped | `lambda-ecr-smoke.sh` | — | [lambda-ecr-pull](./lambda-ecr-pull) |
| SNS large topic → SQS / Lambda | partial | `sns-max-message-size-smoke.sh` | — | [sns-large-topic](./sns-large-topic) |
| Transfer connector S3 → remote SFTP | partial | `transfer-connector-smoke.sh` | — | [transfer-connector](./transfer-connector) |
| RDS Create database → SQL | shipped | `rds-smoke.sh`, `rds-mysql-smoke.sh` | [rds-databases](/assets/console/rds-databases.png) | [rds-create-sql](./rds-create-sql) |
| CloudWatch Logs create / detail | partial | `logs-smoke.sh`, `logs-authz-smoke.sh` | [logs-create-log-group](/assets/console/logs-create-log-group.png) | [cloudwatch-logs-console](./cloudwatch-logs-console) |
