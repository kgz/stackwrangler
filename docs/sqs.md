# SQS (local)

LocalEmu `sqs` on `:4566` (`SERVICES` includes `sqs`).

```bash
./bin/stackwrangler up --force   # after enabling sqs in compose
./smokes/messaging/sqs-smoke.sh
./smokes/messaging/sqs-authz-smoke.sh
./smokes/lambda/sqs-lambda-queueurl-smoke.sh   # Lambda SendMessage via CreateQueue QueueUrl (#459)
./smokes/compute/ecs-sqs-queueurl-smoke.sh     # ECS SendMessage via CreateQueue QueueUrl (#463)
./smokes/lambda/sqs-lambda-dlq-smoke.sh   # needs python3 boto3
./smokes/lambda/sqs-lambda-batch-failures-smoke.sh   # ReportBatchItemFailures; needs python3 boto3
./smokes/lambda/sqs-lambda-esm-enable-smoke.sh
./smokes/lambda/sqs-lambda-esm-cred-refresh-smoke.sh   # needs AWSBOX_STS_ASSUME_ROLE_DURATION + recreate
```

| Area | Status |
|------|--------|
| create / send / receive / delete | Working (smoke) |
| QueueUrl `sqs.<region>.localhost` from Lambda/ECS | Working — `--add-host` to LocalEmu docker IP (`sqs-lambda-queueurl-smoke.sh`, `ecs-sqs-queueurl-smoke.sh`; [lambda-vpc.md](lambda-vpc.md) · [#459](https://github.com/kgz/awsl/issues/459) · [#463](https://github.com/kgz/awsl/issues/463)) |
| MessageRetentionPeriod outside 60–1209600 | Working — `InvalidAttributeValue` (`sqs-smoke.sh`) |
| MessageRetentionPeriod expiry | Working when `SQS_ENABLE_MESSAGE_RETENTION_PERIOD=1` in compose (`sqs-lambda-esm-enable-smoke.sh`) |
| Deny-user SendMessage | Working (`sqs-authz-smoke.sh`) |
| SNS → SQS delivery respects queue policy (`aws:SourceArn`) | Working (`sns-sqs-fanout-smoke.sh`) |
| SNS → SQS refuses `KmsMasterKeyId=alias/aws/sqs` | Working (`sns-sqs-fanout-smoke.sh`; use SQS-managed SSE or a CMK that allows SNS) |
| SNS → SQS CMK must Allow `sns.amazonaws.com` `kms:GenerateDataKey` and `kms:Decrypt` | Working (`sns-sqs-fanout-smoke.sh`; missing grant is a silent drop, grant delivers) |
| SQS → Lambda ESM + DLQ | Working (`sqs-lambda-dlq-smoke.sh`; create refuses role without ReceiveMessage/DeleteMessage/GetQueueAttributes when `IAM_ENFORCEMENT=1`; VisibilityTimeout < function timeout; MaximumConcurrency < 2; post-create revoke stops poll + LastProcessingResult/State, re-grant resumes + clears LPR [#285](https://github.com/kgz/awsl/issues/285) [#449](https://github.com/kgz/awsl/issues/449)) |
| SQS → Lambda ReportBatchItemFailures | Working (`sqs-lambda-batch-failures-smoke.sh`; partial batch retry + DLQ; empty failures delete all; unknown `itemIdentifier` fails batch; response ignored without `FunctionResponseTypes`) |
| SQS → Lambda ESM enable/disable | Working (`sqs-lambda-esm-enable-smoke.sh`; Disabled holds; re-enable drains; MessageRetentionPeriod drops expired) · [#446](https://github.com/kgz/awsl/issues/446) |
| SQS → Lambda ESM credential refresh | Working (`sqs-lambda-esm-cred-refresh-smoke.sh`; short `AWSBOX_STS_ASSUME_ROLE_DURATION`; refresh past expiry; `LastProcessingResult` on hard fail) · [#475](https://github.com/kgz/awsl/issues/475) |
| Lambda reserved concurrency (direct + SQS ESM) | Working (`lambda-reserved-concurrency-smoke.sh`; PutFunctionConcurrency throttle; ESM in-flight ≤ reserved; ESM `ScalingConfig.MaximumConcurrency` vs reserved lower-wins; MC alone when reserved unset) · [#453](https://github.com/kgz/awsl/issues/453) [#498](https://github.com/kgz/awsl/issues/498) |
| Console | Not wired — Debt from #64 → [#167](https://github.com/kgz/awsl/issues/167) |
