# Serverless Framework against awsbox
# Serverless Framework against stackwrangler
This document is about **Serverless Framework** (v3/v4) pointed at the local stackwrangler account. It is unrelated to Cloudflare Wrangler.
./bin/stackwrangler up
./bin/stackwrangler-profile write --force
- Yarn workspace: [examples/serverless-v4-workspace](../examples/serverless-v4-workspace/) — `stackwrangler sls --cwd packages/service` mounts the workspace root when `.bin/serverless` is hoisted ([#468](https://github.com/kgz/awsl/issues/468)); smoke `./smokes/iac/serverless-v4-workspace-smoke.sh`
| Maintainer local alias | `SERVERLESS_LOCAL_ONLY_LICENCE_KEY` | Mapped to `SERVERLESS_LICENSE_KEY` when the latter is unset (`./bin/stackwrangler sls` + smoke) | No |
2. Wrapper: `./bin/stackwrangler sls` (also `./bin/awsbox sls`) runs the CLI in a Node container on that network with `--dns <aws-redirect>`, `NODE_EXTRA_CA_CERTS`, fake keys, **no** `AWS_ENDPOINT_URL`, **no** `~/.aws` mount. The container runs as the host user (`--user $(id -u):$(id -g)`) with `HOME` on `.awsbox/sls-home` (Framework download cache) so `.serverless/` and build output are not root-owned on the project mount ([#469](https://github.com/kgz/awsl/issues/469)).
./bin/stackwrangler up
./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/topic -- deploy --stage local
./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/consumer -- deploy --stage local
`./bin/stackwrangler sls --cwd <package>` mounts the **workspace root** when the package’s `node_modules/.bin/serverless` (or `node_modules`) resolves above the package — yarn classic hoists that `.bin` as a symlink into the root — and sets the container workdir to the package. That keeps sibling workspace packages (e.g. `node_modules/@scope/*` → `packages/…`) resolvable for esbuild.
Prefer `./bin/stackwrangler sls -- … deploy`. If deploy hangs on S3 artifact upload (historically: aws-redirect deadlocked on `Expect: 100-continue` for zips ≳1 MB — fixed in [#467](https://github.com/kgz/awsl/issues/467)), or you need a path that never uses SDK v2 PutObject through the TLS edge:
./bin/stackwrangler up
./bin/stackwrangler sls --cwd examples/serverless-v4-sns-sqs/topic -- package --stage local
`package` still needs a valid Access/License key (licence host is not AWS DNS). `./bin/stackwrangler sls -- … deploy` treats a CLI exit 0 with no `Service deployed` / stack-complete marker as failure.


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
- Smoke: `./smokes/iac/serverless-v3-smoke.sh` (deploy → `/public/health` → redeploy → remove)
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
- Smoke: `./smokes/iac/serverless-v4-smoke.sh` (happy: deploy topic → consumer → SNS keep → Lambda S3 → redeploy → remove; sad [#460](https://github.com/kgz/awsl/issues/460): missing auth, host aws without `AWS_ENDPOINT_URL` refuses real AWS, TLS-down, missing `Fn::ImportValue`, filter-drop)
- Yarn workspace: [examples/serverless-v4-workspace](../examples/serverless-v4-workspace/) — `stackwrangler sls --cwd packages/service` mounts the workspace root when `.bin/serverless` is hoisted ([#468](https://github.com/kgz/awsl/issues/468)); smoke `./smokes/iac/serverless-v4-workspace-smoke.sh`
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
2. Wrapper: `./bin/stackwrangler sls` (also `./bin/awsbox sls`) runs the CLI in a Node container on that network with `--dns <aws-redirect>`, `NODE_EXTRA_CA_CERTS`, fake keys, **no** `AWS_ENDPOINT_URL`, **no** `~/.aws` mount. The container runs as the host user (`--user $(id -u):$(id -g)`) with `HOME` on `.awsbox/sls-home` (Framework download cache) so `.serverless/` and build output are not root-owned on the project mount ([#469](https://github.com/kgz/awsl/issues/469)).
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

Example: [examples/serverless-v4-workspace](../examples/serverless-v4-workspace/) (`packages/service` imports `@awsbox/ws-shared`). Smoke: `./smokes/iac/serverless-v4-workspace-smoke.sh`.

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

### Deploy as the deploy role (admin keys skip IAM)

`stackwrangler sls` deploys with the admin keys. Admin keys skip IAM, so the deploy **can't fail on permissions**. A stack that deploys cleanly here can still get `AccessDenied` in CI, where it runs as a deploy role.

Example: a deploy role's policy scoped `logs:DescribeLogGroups` to log group ARNs. That action has no resource-level permissions (AWS service reference), so a scoped grant never matches, and CloudFormation's `AWS::Logs::LogGroup` handler calls it on every operation. Acting as a role with that exact statement, LocalEmu **denies** `describe-log-groups`, as AWS does. The stack had been deployed with admin keys, so it never showed.

When the question is "will this deploy in CI", deploy as the role CI uses:

1. Create the role from the real policy, with ARNs rewritten for the emulator (account `000000000000`, your region and stage), and a trust policy for the local root.
2. `aws sts assume-role` against the emulator, then export `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.
3. Today: `package` via the redirect, then `aws cloudformation deploy` (fallback above) with those credentials. Built in: `stackwrangler sls --role-arn` ([#522](https://github.com/kgz/awsl/issues/522)).
4. Read the stack events for `AccessDenied`; also `remove` the stack, since rollback and delete need their own permissions.

Known blind spots: SNS `sns:Protocol` / `sns:Endpoint` conditions ([#518](https://github.com/kgz/awsl/issues/518)). Loosen only the affected statement, and say so.

`iam:SimulateCustomPolicy` / `SimulatePrincipalPolicy` evaluate with the same enforcer matchers as live calls (`./smokes/security/iam-simulate-policy-smoke.sh`). That can differ from real AWS’s IAM policy simulator for some resource-scoped actions (e.g. SNS attribute APIs on a topic ARN) — prefer the enforcer answer when checking deploy-role policies locally.

### Lambda → SQS from inside the function

This fixture validates **host SNS publish → SQS → Lambda ESM → S3**. Producers that call `SendMessage` with a QueueUrl host `sqs.<region>.localhost` from inside a Lambda container need [#459](https://github.com/kgz/awsl/issues/459).

## Gaps

| Gap | Ticket |
|-----|--------|
| REQUEST authorizer via Serverless `http` + CFN `PutMethod` | [#328](https://github.com/kgz/awsl/issues/328) |
| `serverless-domain-manager` | [#329](https://github.com/kgz/awsl/issues/329) |
| Smoke sad path (v3) | [#330](https://github.com/kgz/awsl/issues/330) |
| Smoke sad path (v4) | covered in `serverless-v4-smoke.sh` ([#460](https://github.com/kgz/awsl/issues/460)) |
| Deploy as a given role (`--role-arn`) | [#522](https://github.com/kgz/awsl/issues/522) |
