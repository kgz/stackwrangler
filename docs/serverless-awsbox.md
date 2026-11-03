# Serverless Framework against awsbox

Use Serverless Framework against LocalEmu (`:4566`), not SeaweedFS S3.

## Endpoint + profile

```bash
./bin/awsbox up
./bin/awsbox-profile write --force

export AWS_ENDPOINT_URL="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
export AWS_ACCESS_KEY_ID=awsbox
export AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1
```

`AWS_ENDPOINT_URL` must point at LocalEmu for **all** SDK calls, including the deployment bucket. Profile `local` alone sends S3 to SeaweedFS (`:8333`); Lambda/CFN would not see those artifacts.

You can still pass `--aws-profile local` for credentials if you prefer, but keep `AWS_ENDPOINT_URL` set.

Optional S3-specific endpoint (virtual-hosted style clients):

```bash
export AWS_ENDPOINT_URL_S3=http://s3.localhost.localstack.cloud:4566
```

(`s3.localhost.localstack.cloud` resolves to `127.0.0.1` on the awsbox host hosts file / typical LocalStack DNS mapping.)

## v3

- Example: [examples/serverless-v3-rest](../examples/serverless-v3-rest/)
- Smoke: `./bin/serverless-v3-smoke.sh` (deploy → `/public/health` → redeploy → remove)
- Slice status: `./bin/serverless-v3-fixture-check.sh`
- Uses plugins: `serverless-esbuild`, `serverless-iam-roles-per-function`, `serverless-localstack`

Pre-create the named deployment bucket and an SSM string (LocalEmu reserves `/awsbox*` parameter names):

```bash
aws s3 mb "s3://awsbox-sls-deploy" --endpoint-url "$AWS_ENDPOINT_URL"
aws ssm put-parameter --name /demo/rest/dev/app-name --type String --value my-app \
  --overwrite --endpoint-url "$AWS_ENDPOINT_URL"
```

## v4

- Example: [examples/serverless-v4-sns-sqs](../examples/serverless-v4-sns-sqs/) (topic stack + SQS consumer)
- Smoke: `./bin/serverless-v4-smoke.sh` (deploy topic → deploy consumer → SNS publish → Lambda S3 marker → redeploy → remove)
- Shape: `frameworkVersion: "4"`, `deploymentMethod: direct`, named `deploymentBucket`, built-in `build.esbuild` (`exclude: ["@aws-sdk/*"]`), native per-function `iamRoleStatements`, `${ssm:…}`, cross-stack `Fn::ImportValue` — **no** `serverless-localstack` / esbuild / iam-roles plugins

### Licence / auth (every command)

v4 requires authentication for **all** CLI commands, including `serverless package`. There is no offline free/dev bypass.

| Method | Env | Who | Offline? |
|--------|-----|-----|----------|
| Dashboard Access Key | `SERVERLESS_ACCESS_KEY` | Free individuals / orgs under $2M revenue; CI | No — CLI validates against Serverless Inc |
| License Key | `SERVERLESS_LICENSE_KEY` | Paid subscription only | No — still phones home to validate the key (disables Dashboard features) |
| Interactive `serverless login` | (stores local access key) | Local machines | No |

Put the key in the environment (or `.env` sourced by smokes). Do **not** commit keys. Optional: store a License Key in the **target** account as SSM `/serverless-framework/license-key` (Framework auto-reads it) — against LocalEmu that still needs a real key value and network to validate.

Fake / empty keys fail with `Forbidden`.

### Custom endpoint route (preferred)

1. Export `SERVERLESS_ACCESS_KEY` or `SERVERLESS_LICENSE_KEY`
2. Export `AWS_ENDPOINT_URL=http://127.0.0.1:4566` (and credentials as above)
3. `npx serverless deploy --stage local` from each service dir

`AWS_ENDPOINT_URL` alone is enough for the awsbox path (SDK v3 honors it). The smoke also sets `AWS_ENDPOINT_URL_S3` for clients that prefer virtual-hosted S3 URLs.

### Fallback: `package` then CloudFormation

If `deploy` mis-routes to real AWS despite `AWS_ENDPOINT_URL`:

```bash
npx serverless package --stage local
# Upload .serverless/*.zip to the LocalEmu deployment bucket, then:
aws cloudformation deploy \
  --template-file .serverless/cloudformation-template-update-stack.json \
  --stack-name <service>-local \
  --capabilities CAPABILITY_NAMED_IAM \
  --endpoint-url "$AWS_ENDPOINT_URL"
```

`package` still needs a valid Access/License key. Prefer fixing the endpoint env over this path.

### Lambda → SQS from inside the function

This fixture validates **host SNS publish → SQS → Lambda ESM → S3**. Producers that call `SendMessage` with a QueueUrl host `sqs.<region>.localhost` from inside a Lambda container need [#459](https://github.com/kgz/awsl/issues/459).

## Gaps

| Gap | Ticket |
|-----|--------|
| REQUEST authorizer via Serverless `http` + CFN `PutMethod` | [#328](https://github.com/kgz/awsl/issues/328) |
| `serverless-domain-manager` | [#329](https://github.com/kgz/awsl/issues/329) |
| Smoke sad path (v3) | [#330](https://github.com/kgz/awsl/issues/330) |
| Smoke sad path (v4) | [#460](https://github.com/kgz/awsl/issues/460) |
