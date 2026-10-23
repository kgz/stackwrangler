# Messaging / data / crypto smokes (LocalEmu)

Requires `SERVICES` including: `sqs,sns,events,dynamodb,stepfunctions,secretsmanager,kms,kinesis` (see `docker-compose.yml`). Recreate LocalEmu after compose changes:

```bash
docker compose up -d --force-recreate localstack
# or: ./bin/awsbox up --force
```

| Surface | Happy | Sad |
|---------|-------|-----|
| SQS | `sqs-smoke.sh` | `sqs-authz-smoke.sh` |
| SNS | `sns-smoke.sh` | `sns-authz-smoke.sh` |
| SNS → SQS fan-out | `sns-sqs-fanout-smoke.sh` (envelope, raw, filter) | same (wrong/missing queue `SourceArn`; unsubscribe) |
| EventBridge | `events-smoke.sh` | `events-authz-smoke.sh` |
| DynamoDB | `dynamodb-smoke.sh` | `dynamodb-authz-smoke.sh` |
| Step Functions | `sfn-smoke.sh` | `sfn-authz-smoke.sh` |
| Secrets Manager | `secrets-smoke.sh` | `secrets-authz-smoke.sh` |
| KMS | `kms-smoke.sh` | `kms-authz-smoke.sh` |
| Kinesis | `kinesis-smoke.sh` | `kinesis-authz-smoke.sh` |
| Logs / API GW / EC2 | existing happy | `logs-authz-smoke.sh`, `apigw-authz-smoke.sh`, `ec2-authz-smoke.sh` |

Console for each is Debt (#167, #172–#178). Real-AWS parity for this batch is a follow-up.
