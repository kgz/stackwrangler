# Messaging / data / crypto smokes (LocalEmu)

Requires `SERVICES` including: `sqs,sns,events,scheduler,dynamodb,stepfunctions,secretsmanager,kms,kinesis` (see `docker-compose.yml`). Recreate LocalEmu after compose changes:

```bash
docker compose up -d --force-recreate localstack
# or: ./bin/stackwrangler up --force
```

| Surface | Happy | Sad |
|---------|-------|-----|
| SQS | `sqs-smoke.sh` | `sqs-authz-smoke.sh` |
| SNS | `sns-smoke.sh` · `sns-subscribe-conditions-smoke.sh` | `sns-authz-smoke.sh` · `sns-subscribe-conditions-smoke.sh` |
| SNS MaximumMessageSize | `sns-max-message-size-smoke.sh` (CreateTopic/Set + 300 KiB–1 MiB → SQS raw; large-topic sqs/lambda/firehose) | same (default >256 KiB; http/email/sms/application subscribe + Set with http sub → InvalidParameter) |
| SNS → SQS fan-out | `sns-sqs-fanout-smoke.sh` (envelope, raw, filter; CMK with SNS grant) | same (wrong/missing queue `SourceArn`; `alias/aws/sqs` KMS; CMK without SNS grant; unsubscribe) |
| EventBridge | `events-smoke.sh` | `events-authz-smoke.sh` |
| EventBridge Scheduler trust SourceArn | `scheduler-trust-sourcearn-smoke.sh` (SourceAccount; schedule-group ArnLike → SQS) | same (wrong account / group → DLQ) |
| DynamoDB | `dynamodb-smoke.sh` | `dynamodb-authz-smoke.sh` |
| DynamoDB depth | `dynamodb-depth-smoke.sh` (GSI, conditions, UpdateItem, transactions, TTL) | same (index/table ARNs; Batch/Transact [#306](https://github.com/kgz/awsl/issues/306); index `aws:ResourceTag` [#307](https://github.com/kgz/awsl/issues/307)) |
| DynamoDB depth | `dynamodb-depth-smoke.sh` (GSI, conditions, UpdateItem, transactions, TTL) | same (index/table ARNs + Transact/Batch table-scoped); gap [#307](https://github.com/kgz/awsl/issues/307) |
| DynamoDB resource policy + SourceVpce | `dynamodb-resource-policy-smoke.sh` | same (Deny without VPCE; wrong VPCE; PrincipalArn exception) |
| DynamoDB depth | `dynamodb-depth-smoke.sh` (GSI, conditions, UpdateItem, transactions, TTL) | same (index/table ARNs); gaps [#306](https://github.com/kgz/awsl/issues/306), [#307](https://github.com/kgz/awsl/issues/307) |
| Step Functions | `sfn-smoke.sh` | `sfn-authz-smoke.sh` |
| Secrets Manager | `secrets-smoke.sh` | `secrets-authz-smoke.sh` |
| KMS | `kms-smoke.sh` | `kms-authz-smoke.sh` |
| Kinesis | `kinesis-smoke.sh` | `kinesis-authz-smoke.sh` |
| Kinesis / DynamoDB stream → Lambda ESM credential refresh | `stream-lambda-esm-cred-refresh-smoke.sh` (short `AWSBOX_STS_ASSUME_ROLE_DURATION`; deliver past expiry) · [#477](https://github.com/kgz/awsl/issues/477) | SQS smoke covers role-delete `LastProcessingResult` on shared path · [#475](https://github.com/kgz/awsl/issues/475) |
| Logs / API GW / EC2 | existing happy | `logs-authz-smoke.sh`, `apigw-authz-smoke.sh`, `ec2-authz-smoke.sh` |

Console: SNS Topics thin list (#172); create/detail [#546](https://github.com/kgz/awsl/issues/546); Kinesis list/create/detail (#178 / #539); remaining messaging consoles Debt (#167, #173–#177).
Console: SNS Topics thin list (#172); create/detail [#546](https://github.com/kgz/awsl/issues/546); Kinesis list/create/detail/put/tags (#178 / #539 / #615); remaining messaging consoles Debt (#167, #173–#177).

Real-AWS parity: `./smokes/parity/aws-parity-batch10.sh` · [aws-parity-batch10.md](aws-parity-batch10.md).  
HF cheap (DDB depth + schedule + REST/keys + S3 GW VPCE): `./smokes/parity/aws-parity-hf-cheap.sh` · [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md).

## DynamoDB depth (#296)

`./smokes/data/dynamodb-depth-smoke.sh` deploys `examples/serverless-v3-rest/slices/ddb/resources.yml` (token table, GSI `tokenHash-index`, TTL `expiresAt`) through CloudFormation.

- IAM: `Query`/`Scan` with `IndexName` are evaluated on `table/<t>/index/<i>` (patch `localemu-patches/iam_arn_builder.py`). Allow on the table ARN does not cover the index. Index ARNs inherit table tags for `aws:ResourceTag/*` (`localemu-patches/resource_tag_loader.py`, #307).
- IAM: `Query`/`Scan` with `IndexName` are evaluated on `table/<t>/index/<i>` (patch `localemu-patches/iam_arn_builder.py`). Allow on the table ARN does not cover the index.
- IAM: `TransactWriteItems` / `TransactGetItems` / `BatchWriteItem` / `BatchGetItem` evaluate each item or table separately (per-item action for Transact*, per-table `Batch*` action + ARN; patches `service_action_map.py` + `iam_enforcer.py`).
- TTL: LocalEmu sweeps hourly. The smoke triggers the sweep with `DELETE <endpoint>/_aws/dynamodb/expired` (not an AWS API; override with `AWSBOX_DDB_EXPIRE_URL`). Real AWS deletes within about 48h.
