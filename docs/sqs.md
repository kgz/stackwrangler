# SQS (local)

LocalEmu `sqs` on `:4566` (`SERVICES` includes `sqs`).

```bash
./bin/awsbox up --force   # after enabling sqs in compose
./bin/sqs-smoke.sh
./bin/sqs-authz-smoke.sh
./bin/sqs-lambda-dlq-smoke.sh   # needs python3 boto3
```

| Area | Status |
|------|--------|
| create / send / receive / delete | Working (smoke) |
| MessageRetentionPeriod outside 60–1209600 | Working — `InvalidAttributeValue` (`sqs-smoke.sh`) |
| Deny-user SendMessage | Working (`sqs-authz-smoke.sh`) |
| SNS → SQS delivery respects queue policy (`aws:SourceArn`) | Working (`sns-sqs-fanout-smoke.sh`) |
| SNS → SQS refuses `KmsMasterKeyId=alias/aws/sqs` | Working (`sns-sqs-fanout-smoke.sh`; use SQS-managed SSE or a CMK that allows SNS) |
| SNS → SQS CMK must Allow `sns.amazonaws.com` `kms:GenerateDataKey` and `kms:Decrypt` | Working (`sns-sqs-fanout-smoke.sh`; missing grant is a silent drop, grant delivers) |
| SQS → Lambda ESM + DLQ | Working (`sqs-lambda-dlq-smoke.sh`; create refuses role without ReceiveMessage/DeleteMessage/GetQueueAttributes when `IAM_ENFORCEMENT=1`; VisibilityTimeout < function timeout; MaximumConcurrency < 2) · post-create revoke [#285](https://github.com/kgz/awsl/issues/285) |
| Lambda reserved concurrency (direct + SQS ESM) | Working for PutFunctionConcurrency throttle + ESM in-flight cap (`lambda-reserved-concurrency-smoke.sh`); ESM `ScalingConfig.MaximumConcurrency` vs reserved lower-wins not enforced — [#453](https://github.com/kgz/awsl/issues/453) |
| Console | Not wired — Debt from #64 → [#167](https://github.com/kgz/awsl/issues/167) |
