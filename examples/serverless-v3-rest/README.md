# serverless-v3-rest (replication fixture)

Dummy [Serverless Framework v3](https://www.serverless.com/) project that mimics a real REST stack for awsbox. Handlers are stubs; the AWS shape matters. Parent ticket: [#185](https://github.com/kgz/awsl/issues/185). Each slice under `slices/<name>/` is standalone so a ticket's smoke runs without the rest.

| Piece | Role |
|-------|------|
| `serverless.yml` | `deploymentMethod: direct`, named deploy bucket, esbuild, per-function IAM, `${ssm:…}`, http + schedule + S3 events |
| `resources/cfn.yml` | DynamoDB, KMS, Secrets Manager |
| `resources/rest-api.js` | `AWS::ApiGateway::RestApi` with OpenAPI `Body` |
| `resources/vpc-link-ecs.yml` | VPC Link → internal NLB → ECS shape stub (`DesiredCount: 0`) |
| S3 uploads bucket | Created by the `onObject` `s3` event (not in `cfn.yml`) |
| `slices/<name>/` | Standalone services from later tickets (each has its own smoke) |

`serverless-domain-manager` is **not** wired here ([#329](https://github.com/kgz/awsl/issues/329); custom domain via CLI: `./bin/apigw-rest-smoke.sh`). REQUEST authorizer on Serverless `http` events is deferred ([#328](https://github.com/kgz/awsl/issues/328)); the authorizer Lambda is still deployed for shape.

## Against awsbox

```bash
./bin/awsbox up
./bin/awsbox-profile write --force   # credentials for profile local

# All Serverless AWS calls (including S3 artifacts) must hit LocalEmu, not SeaweedFS.
# Profile `local` sends S3 to :8333 — override with AWS_ENDPOINT_URL.
export AWS_ENDPOINT_URL="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
export AWS_ACCESS_KEY_ID=awsbox AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1
# Optional: --aws-profile local for keys; still set AWS_ENDPOINT_URL so S3 hits LocalEmu (:4566), not SeaweedFS (:8333).

aws s3 mb "s3://awsbox-sls-deploy" --endpoint-url "$AWS_ENDPOINT_URL"
aws ssm put-parameter --name /demo/rest/dev/app-name --type String --value my-app --overwrite \
  --endpoint-url "$AWS_ENDPOINT_URL"
# LocalEmu reserves /awsbox* SSM names.

cd examples/serverless-v3-rest && npm i
export AWSBOX_SLSE_DEPLOY_BUCKET=awsbox-sls-deploy AWSBOX_SLSE_SUFFIX=dev
npx serverless deploy --stage local
```

Smoke (creates deploy bucket + SSM param, deploy → invoke → redeploy → remove):

```bash
./bin/serverless-v3-smoke.sh
```

Slice status (parent + any `slices/*` present):

```bash
./bin/serverless-v3-fixture-check.sh
```

## Slices

| Slice | Ticket | Smoke |
|-------|--------|-------|
| _(parent)_ | [#185](https://github.com/kgz/awsl/issues/185) | `./bin/serverless-v3-smoke.sh` |
| [api-keys](slices/api-keys/) | [#294](https://github.com/kgz/awsl/issues/294) | `./bin/apigw-usage-plan-smoke.sh` |
| [transfer-out](slices/transfer-out/) | [#295](https://github.com/kgz/awsl/issues/295) | `./bin/transfer-connector-smoke.sh` |
| [ddb](slices/ddb/) | [#296](https://github.com/kgz/awsl/issues/296) | `./bin/dynamodb-depth-smoke.sh` |
| [schedule](slices/schedule/) | [#297](https://github.com/kgz/awsl/issues/297) | `./bin/events-schedule-smoke.sh` |
| [apigw-authz](slices/apigw-authz/) | [#190](https://github.com/kgz/awsl/issues/190) | `./bin/apigw-rest-smoke.sh` |
| [transfer-in](slices/transfer-in/) | [#141](https://github.com/kgz/awsl/issues/141) | `./bin/transfer-key-smoke.sh` |
| [waf](slices/waf/) | [#55](https://github.com/kgz/awsl/issues/55) | `./bin/waf-smoke.sh` |
| [dns](slices/dns/) | [#56](https://github.com/kgz/awsl/issues/56) | `./bin/route53-smoke.sh` |
| [acm](slices/acm/) | [#74](https://github.com/kgz/awsl/issues/74) | `./bin/acm-smoke.sh` |
| [asg](slices/asg/) | [#83](https://github.com/kgz/awsl/issues/83) | `./bin/autoscaling-smoke.sh` |
