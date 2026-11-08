# SQS → Lambda (event source mapping)

Queue messages trigger a Lambda via event source mapping. Credential refresh and authz depth vary by smoke; treat as **partial** until the ESM path you need is listed green in the matrix.

**Status:** partial · See matrix rows for SQS / Lambda ESM and related Debt tickets

## Sequence

1. Create queue + function + event source mapping.
2. Send message; function consumes.
3. Confirm mapping enabled; sad paths depend on the specific smoke (role delete, deny, etc.).

## Prove it

Named smokes (need `python3` + `boto3`; cred-refresh needs short `AWSBOX_STS_ASSUME_ROLE_DURATION` + LocalEmu recreate):

- `./smokes/lambda/sqs-lambda-esm-cred-refresh-smoke.sh` — SQS past STS expiry + role-delete `LastProcessingResult` · [#475](https://github.com/kgz/awsl/issues/475)
- `./smokes/lambda/stream-lambda-esm-cred-refresh-smoke.sh` — Kinesis + DynamoDB stream past STS expiry · [#477](https://github.com/kgz/awsl/issues/477)
- Also: `sqs-lambda-dlq-smoke.sh`, `sqs-lambda-batch-failures-smoke.sh`, `sqs-lambda-esm-enable-smoke.sh`

Search [test-paths](https://github.com/kgz/stackwrangler/blob/main/docs/test-paths.md) for `ESM` / `event source` for the full set. Do not claim unlisted ESM behaviours.
