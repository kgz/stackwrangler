## Why

Spec-first stacks (Serverless `resources`, CloudFormation `AWS::ApiGateway::RestApi` with a `Body`) deploy REST APIs (v1) from an OpenAPI document, with Lambda REQUEST authorizers and public routes such as OAuth callbacks. awsbox only exercised HTTP APIs (v2). A probe showed LocalEmu already handles most of v1, so this change proves it with a smoke and an example, enables what custom domains need, and records the gaps.

## What Changes

- `examples/apigw-rest/`: generic OpenAPI template, handler and REQUEST authorizer
- `bin/apigw-rest-smoke.sh`: import, deploy, then a public route, query passthrough, no token, Deny, Allow with context, unknown route, and custom domain + base-path mapping (control plane); wired into `bin/e2e.sh`
- `route53,acm` added to LocalEmu `SERVICES` (needed by `create-domain-name`) and to profile `local`
- Docs: `docs/apigw-rest.md`, smoke matrix, test paths, README row

## Non-goals

- Console REST APIs (#189)
- Fixing Deny → 401 vs AWS 403 (#190)
- Routing requests by custom domain (#191)
- `http_proxy` / VPC_LINK integrations
- Serverless Framework deploy (#185)

## Capabilities

### New Capabilities

- `apigw-rest`: REST APIs imported from OpenAPI, with `aws_proxy` routes and REQUEST Lambda authorizers

### Modified Capabilities

(none)

## Impact

- `docker-compose.yml`, `bin/awsbox-profile`, `bin/apigw-rest-smoke.sh`, `bin/e2e.sh`, `examples/apigw-rest/`, docs
- Issue: #184 · Debt: #189, #190, #191
