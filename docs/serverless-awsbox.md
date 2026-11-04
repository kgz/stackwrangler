# Serverless Framework against awsbox

Use Serverless Framework against LocalEmu (`:4566`), not SeaweedFS S3.

## Endpoint + profile

```bash
./bin/stackwrangler up
./bin/awsbox-profile write --force

export AWS_ACCESS_KEY_ID=awsbox
export AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1
```

For **host** AWS CLI / SDK v3 calls against LocalEmu:

```bash
export AWS_ENDPOINT_URL="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
```

`AWS_ENDPOINT_URL` must point at LocalEmu for those clients (including deployment-bucket prep). Profile `local` alone sends S3 to SeaweedFS (`:8333`).

Optional S3-specific endpoint (virtual-hosted style clients):

```bash
export AWS_ENDPOINT_URL_S3=http://s3.localhost.localstack.cloud:4566
```

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
- Yarn workspace: [examples/serverless-v4-workspace](../examples/serverless-v4-workspace/) — `stackwrangler sls --cwd packages/service` mounts the workspace root when `.bin/serverless` is hoisted ([#468](https://github.com/kgz/awsl/issues/468)); smoke `./bin/serverless-v4-workspace-smoke.sh`
- Shape: `frameworkVersion: "4"`, `deploymentMethod: direct`, named `deploymentBucket`, built-in `build.esbuild` (`exclude: ["@aws-sdk/*"]`), native per-function `iamRoleStatements`, `${ssm:…}`, cross-stack `Fn::ImportValue` — **no** `serverless-localstack` / esbuild / iam-roles plugins

### Licence / auth (every command)

v4 requires authentication for **all** CLI commands, including `serverless package`. There is no offline free/dev bypass.

| Method | Env | Who | Offline? |
|--------|-----|-----|----------|
| Dashboard Access Key | `SERVERLESS_ACCESS_KEY` | Free individuals / orgs under $2M revenue; CI | No — CLI validates against Serverless Inc |
| License Key | `SERVERLESS_LICENSE_KEY` | Paid subscription | No — still phones home to validate the key |
| Maintainer local alias | `SERVERLESS_LOCAL_ONLY_LICENCE_KEY` | Mapped to `SERVERLESS_LICENSE_KEY` when the latter is unset (`./bin/stackwrangler sls` + smoke) | No |
| Interactive `serverless login` | (stores local access key) | Local machines | No |

Put the key in the environment (or `.env` sourced by smokes). Do **not** commit keys. See [`.env.example`](../.env.example) for the variable names.

Fake / empty keys fail with `Forbidden`.

### Deploy path: aws-redirect (required for `deploy` / `remove`)

Serverless Framework v4’s deploy path uses the AWS SDK **v2** bundled under `~/.serverless/releases/…/aws-sdk`. That SDK **ignores** `AWS_ENDPOINT_URL`, so `sts.amazonaws.com` / `cloudformation.<region>.amazonaws.com` would hit **real AWS**. Fake awsbox keys then fail with an invalid-token error; real keys on the machine would land in a real account.

Use the transparent redirect instead:

1. Compose profile `aws-redirect` — dual-role container under [`tools/aws-endpoint-redirect/`](../tools/aws-endpoint-redirect/): dnsmasq (AWS hostnames → proxy IP; everything else upstream) + TLS `:443` with **dynamic leaf certs per SNI** signed by `.awsbox/aws-redirect/ca.crt`, forwarding HTTP to LocalEmu `:4566` with the client `Host` kept.
2. Wrapper: `./bin/stackwrangler sls` (also `./bin/awsbox sls`) runs the CLI in a Node container on that network with `--dns <aws-redirect>`, `NODE_EXTRA_CA_CERTS`, fake keys, **no** `AWS_ENDPOINT_URL`, **no** `~/.aws` mount.
3. Fail closed: AWS names never resolve to public IPs. If the TLS edge is down, clients get a connection error — not real AWS.

```bash
./bin/stackwrangler up
# starts aws-redirect on first use
export SERVERLESS_ACCESS_KEY=…   # or SERVERLESS_LICENSE_KEY / SERVERLESS_LOCAL_ONLY_LICENCE_KEY

cd examples/serverless-v4-sns-sqs && npm i
aws s3 mb s3://awsbox-sls4-deploy --endpoint-url http://127.0.0.1:4566
aws ssm put-parameter --name /demo/sls4/dev/app-name --type String --value my-app \
  --overwrite --endpoint-url http://127.0.0.1:4566

./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/topic -- deploy --stage local
./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/consumer -- deploy --stage local
```

Manual compose (optional): `docker compose --profile aws-redirect up -d aws-redirect`.

### Yarn / npm workspaces

`./bin/stackwrangler sls --cwd <package>` mounts the **workspace root** when the package’s `node_modules/.bin/serverless` (or `node_modules`) resolves above the package — yarn classic hoists that `.bin` as a symlink into the root — and sets the container workdir to the package. That keeps sibling workspace packages (e.g. `node_modules/@scope/*` → `packages/…`) resolvable for esbuild.

Example: [examples/serverless-v4-workspace](../examples/serverless-v4-workspace/) (`packages/service` imports `@awsbox/ws-shared`). Smoke: `./bin/serverless-v4-workspace-smoke.sh`.

Workaround if you prefer not to rely on detection: `--cwd <workspace root> -- deploy --config <package>/serverless.yml` (Serverless resolves `${file(…)}` and handlers relative to the config’s directory).

### Fallback: `package` via redirect, then CloudFormation (AWS CLI)

Prefer `./bin/stackwrangler sls -- … deploy`. If deploy hangs on S3 artifact upload (historically: aws-redirect deadlocked on `Expect: 100-continue` for zips ≳1 MB — fixed in [#467](https://github.com/kgz/awsl/issues/467)), or you need a path that never uses SDK v2 PutObject through the TLS edge:

1. Package through the redirect (same DNS/TLS container; `package` does not upload):
2. Upload `.serverless/*.zip` with the host AWS CLI against LocalEmu.
3. `aws cloudformation deploy` with `--endpoint-url`.

```bash
./bin/stackwrangler up
export SERVERLESS_ACCESS_KEY=…   # or LICENSE / LOCAL_ONLY alias
export AWS_ENDPOINT_URL=http://127.0.0.1:4566

./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/topic -- package --stage local
# Upload .serverless/*.zip to the deployment bucket (aws s3 cp … --endpoint-url "$AWS_ENDPOINT_URL"), then:
aws cloudformation deploy \
  --template-file .serverless/cloudformation-template-update-stack.json \
  --stack-name <service>-local \
  --capabilities CAPABILITY_NAMED_IAM \
  --endpoint-url "$AWS_ENDPOINT_URL"
```

`package` still needs a valid Access/License key (licence host is not AWS DNS). `./bin/stackwrangler sls -- … deploy` treats a CLI exit 0 with no `Service deployed` / stack-complete marker as failure.

### Lambda → SQS from inside the function

This fixture validates **host SNS publish → SQS → Lambda ESM → S3**. Producers that call `SendMessage` with a QueueUrl host `sqs.<region>.localhost` from inside a Lambda container need [#459](https://github.com/kgz/awsl/issues/459).

## Gaps

| Gap | Ticket |
|-----|--------|
| REQUEST authorizer via Serverless `http` + CFN `PutMethod` | [#328](https://github.com/kgz/awsl/issues/328) |
| `serverless-domain-manager` | [#329](https://github.com/kgz/awsl/issues/329) |
| Smoke sad path (v3) | [#330](https://github.com/kgz/awsl/issues/330) |
| Smoke sad path (v4) | [#460](https://github.com/kgz/awsl/issues/460) |
