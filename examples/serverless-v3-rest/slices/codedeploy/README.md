# Slice: codedeploy (#98)

Standalone CodeDeploy shapes for the serverless-v3-rest fixture ([#185](https://github.com/kgz/awsl/issues/185)). Handlers/stubs elsewhere; this slice is the deploy control plane.

| Resource | Shape |
|----------|--------|
| ECS app + deployment group | `computePlatform: ECS`, blue/green with two target groups + prod listener |
| Lambda app + deployment group | `computePlatform: Lambda`, `CodeDeployDefault.LambdaCanary10Percent5Minutes` |

Smoke (does not require the parent Serverless project):

```bash
./bin/awsbox up
./bin/codedeploy-smoke.sh
```

`resources.yml` is the CFN shape the smoke exercises via CLI. Lambda canary **alias weight shift**: [#340](https://github.com/kgz/awsl/issues/340). Authz/console: [#341](https://github.com/kgz/awsl/issues/341).
