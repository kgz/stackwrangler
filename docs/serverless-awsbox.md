# Serverless Framework against awsbox

Use [Serverless Framework v3](https://www.serverless.com/) with LocalEmu (`:4566`), not SeaweedFS S3.

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

You can still pass `--aws-profile local` for credentials if you prefer, but keep `AWS_ENDPOINT_URL` set (and use `serverless-localstack` as in the fixture).

## Fixture + smoke

- Example: [examples/serverless-v3-rest](../examples/serverless-v3-rest/)
- Smoke: `./bin/serverless-v3-smoke.sh` (deploy → `/public/health` → redeploy → remove)
- Slice status: `./bin/serverless-v3-fixture-check.sh`

Pre-create the named deployment bucket and an SSM string (LocalEmu reserves `/awsbox*` parameter names):

```bash
aws s3 mb "s3://awsbox-sls-deploy" --endpoint-url "$AWS_ENDPOINT_URL"
aws ssm put-parameter --name /demo/rest/dev/app-name --type String --value my-app \
  --overwrite --endpoint-url "$AWS_ENDPOINT_URL"
```

## Gaps

| Gap | Ticket |
|-----|--------|
| REQUEST authorizer via Serverless `http` + CFN `PutMethod` | [#328](https://github.com/kgz/awsl/issues/328) |
| `serverless-domain-manager` | [#329](https://github.com/kgz/awsl/issues/329) |
| Smoke sad path | [#330](https://github.com/kgz/awsl/issues/330) |
