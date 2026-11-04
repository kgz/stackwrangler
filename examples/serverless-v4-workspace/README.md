# serverless-v4-workspace

Two-package **yarn** workspace for [#468](https://github.com/kgz/awsl/issues/468): `packages/service` depends on sibling `@awsbox/ws-shared`. Yarn hoists `serverless` so `packages/service/node_modules/.bin/serverless` is a symlink into the workspace root — `./bin/stackwrangler sls --cwd packages/service` must mount the workspace root (not only the package).

| Path | Role |
|------|------|
| `packages/shared` | `@awsbox/ws-shared` — `greet()` |
| `packages/service` | Serverless v4 Lambda; esbuild bundles the sibling |

## Auth

Same as [serverless-v4-sns-sqs](../serverless-v4-sns-sqs/): `SERVERLESS_ACCESS_KEY` or `SERVERLESS_LICENSE_KEY` / `SERVERLESS_LOCAL_ONLY_LICENCE_KEY`.

## Manual

```bash
./bin/stackwrangler up
cd examples/serverless-v4-workspace && yarn install
aws s3 mb s3://awsbox-sls4-ws-deploy --endpoint-url http://127.0.0.1:4566

./bin/stackwrangler sls --cwd examples/serverless-v4-workspace/packages/service -- deploy --stage local
```

## Smoke

```bash
./bin/serverless-v4-workspace-smoke.sh
```
