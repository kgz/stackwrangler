# Real-AWS parity — messaging / data / crypto batch

```bash
./smokes/parity/aws-parity-batch10.sh
```

Local: existing `*-smoke.sh` / `*-authz-smoke.sh`.  
Real: default creds (`AWSBOX_PARITY_REGION`, default `ap-southeast-2`), short-lived create → assert → delete.

| Surface | Happy | Sad |
|---------|-------|-----|
| SNS | publish | deny Publish |
| EventBridge | put-events + rule | deny PutEvents |
| DynamoDB | put/get | deny PutItem |
| Step Functions | Pass | deny StartExecution |
| Secrets | create/get | deny GetSecretValue |
| KMS | encrypt/decrypt | deny Decrypt (+ schedule-key-deletion 7d) |
| Kinesis | put | deny PutRecord |
| Logs | — | deny PutLogEvents |
| API GW | — | deny CreateApi |
| EC2 | — | deny RunInstances (no instance created) |

**Cost:** free-tier/noise if teardown OK. Cleanup is LIFO on `EXIT` (unless `AWSBOX_PARITY_KEEP=1`). KMS CMK pending delete (7-day AWS minimum) = small prorate until deletion completes — the only intentional residual.

`AWSBOX_PARITY_SKIP_LOCAL=1` · `AWSBOX_PARITY_SKIP_REAL=1` · `AWSBOX_PARITY_KEEP=1`
