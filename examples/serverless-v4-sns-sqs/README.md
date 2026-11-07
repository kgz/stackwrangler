# serverless-v4-sns-sqs (replication fixture)

Dummy [Serverless Framework v4](https://www.serverless.com/) project that deploys an SNS topic stack plus an SQS-triggered consumer against awsbox LocalEmu. Parent ticket: [#458](https://github.com/kgz/awsl/issues/458). Deploy redirect: [#464](https://github.com/kgz/awsl/issues/464).

| Path | Shape |
|------|--------|
| `topic/serverless.yml` | SNS topic, SSM `/demo/sls4/…/topic-arn`, CFN `Export` of TopicArn |
| `consumer/serverless.yml` | `deploymentMethod: direct`, named deploy bucket, `build.esbuild` (`exclude: ["@aws-sdk/*"]`), `${ssm:…}`, native `iamRoleStatements`, SQS ESM Lambda, filtered raw SNS→SQS via `!ImportValue` |

v4 `deploy` ignores `AWS_ENDPOINT_URL` (bundled AWS SDK v2). Use `./bin/stackwrangler sls` so DNS+TLS redirect hits LocalEmu — see [docs/serverless-stackwrangler.md](../../docs/serverless-stackwrangler.md).

## Auth (required)

Every v4 CLI command (including `package`) needs Dashboard auth or a License Key. Neither works fully offline — validation hits Serverless Inc.

```bash
# Free / under-$2M org: Dashboard Access Key (Settings → Access Keys)
export SERVERLESS_ACCESS_KEY=…

# Paid subscription License Key
export SERVERLESS_LICENSE_KEY=…

# Maintainer alias (mapped to SERVERLESS_LICENSE_KEY when unset)
export SERVERLESS_LOCAL_ONLY_LICENCE_KEY=…
```

## Manual deploy (redirect)

```bash
./bin/stackwrangler up
./bin/stackwrangler-profile write --force

cd examples/serverless-v4-sns-sqs && npm i
aws s3 mb s3://awsbox-sls4-deploy --endpoint-url http://127.0.0.1:4566
aws ssm put-parameter --name /demo/sls4/dev/app-name --type String --value my-app \
  --overwrite --endpoint-url http://127.0.0.1:4566

./bin/stackwrangler sls --cwd topic -- deploy --stage local
export AWSBOX_SLS4_TOPIC_EXPORT=awsbox-sls4-topic-local-TopicArn
./bin/stackwrangler sls --cwd consumer -- deploy --stage local
```

(`./bin/awsbox sls` is the same shim.)

## Fallback: package via redirect, CFN via AWS CLI

`./bin/stackwrangler sls --cwd … -- package`, upload `.serverless/*.zip`, then
`aws cloudformation deploy --endpoint-url http://127.0.0.1:4566` — see docs
(useful if deploy hangs on large S3 uploads).

## Smoke

```bash
./smokes/iac/serverless-v4-smoke.sh
./smokes/iac/serverless-v4-role-arn-smoke.sh   # --role-arn / --use-session-env (#522)
```

Happy: deploy topic → consumer → SNS publish (filter keep) → Lambda writes S3 → redeploy → remove.
Sad ([#460](https://github.com/kgz/awsl/issues/460)): missing auth; host aws without `AWS_ENDPOINT_URL` refuses real AWS; TLS-down connection error; missing `Fn::ImportValue` deploy fails; filter-drop never reaches S3. DNS log asserts AWS names → proxy only.
Deploy-as-role ([#522](https://github.com/kgz/awsl/issues/522)): see [Deploy as the deploy role](../../docs/serverless-stackwrangler.md#deploy-as-the-deploy-role-admin-keys-skip-iam).

**Note:** This path is host SNS publish → SQS → Lambda ESM → S3. It does not exercise Lambda→SQS `SendMessage` with `sqs.<region>.localhost` QueueUrls ([#459](https://github.com/kgz/awsl/issues/459)).
