# serverless-v4-sns-sqs (replication fixture)

Dummy [Serverless Framework v4](https://www.serverless.com/) project that deploys an SNS topic stack plus an SQS-triggered consumer against awsbox LocalEmu. Parent ticket: [#458](https://github.com/kgz/awsl/issues/458).

| Path | Shape |
|------|--------|
| `topic/serverless.yml` | SNS topic, SSM `/demo/sls4/…/topic-arn`, CFN `Export` of TopicArn |
| `consumer/serverless.yml` | `deploymentMethod: direct`, named deploy bucket, `build.esbuild` (`exclude: ["@aws-sdk/*"]`), `${ssm:…}`, native `iamRoleStatements`, SQS ESM Lambda, filtered raw SNS→SQS via `!ImportValue` |

No `serverless-localstack` plugin — point the CLI at LocalEmu with `AWS_ENDPOINT_URL` (see [docs/serverless-awsbox.md](../../docs/serverless-awsbox.md)).

## Auth (required)

Every v4 CLI command (including `package`) needs Dashboard auth or a License Key. Neither works fully offline — validation hits Serverless Inc.

```bash
# Free / under-$2M org: Dashboard Access Key (Settings → Access Keys)
export SERVERLESS_ACCESS_KEY=…

# Paid subscription License Key (not free-tier)
export SERVERLESS_LICENSE_KEY=…
```

## Manual deploy

```bash
./bin/awsbox up
./bin/awsbox-profile write --force

export AWS_ENDPOINT_URL="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
export AWS_ACCESS_KEY_ID=awsbox
export AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1

cd examples/serverless-v4-sns-sqs && npm i
aws s3 mb s3://awsbox-sls4-deploy --endpoint-url "$AWS_ENDPOINT_URL"
aws ssm put-parameter --name /demo/sls4/dev/app-name --type String --value my-app \
  --overwrite --endpoint-url "$AWS_ENDPOINT_URL"

(cd topic && npx serverless deploy --stage local)
export AWSBOX_SLS4_TOPIC_EXPORT=awsbox-sls4-topic-local-TopicArn
(cd consumer && npx serverless deploy --stage local)
```

## Smoke

```bash
./bin/serverless-v4-smoke.sh
```

Deploy topic → deploy consumer → SNS publish (filter keep) → Lambda writes S3 → redeploy consumer → remove both.

**Note:** This path is host SNS publish → SQS → Lambda ESM → S3. It does not exercise Lambda→SQS `SendMessage` with `sqs.<region>.localhost` QueueUrls ([#459](https://github.com/kgz/awsl/issues/459)).
