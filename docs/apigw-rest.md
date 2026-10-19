# API Gateway REST APIs (v1)

REST APIs imported from an OpenAPI 3 document with `x-amazon-apigateway-*` extensions, the shape spec-first stacks (Serverless `resources`, CloudFormation `AWS::ApiGateway::RestApi` `Body`) deploy.

Example: [examples/apigw-rest](../examples/apigw-rest/) · Smoke: `./bin/apigw-rest-smoke.sh`

## What works

| Feature | Status |
|---------|--------|
| `import-rest-api` from OpenAPI 3 | Working |
| `aws_proxy` Lambda integrations (v1 event: `path`, `httpMethod`, `queryStringParameters`) | Working |
| Routes with no authorizer | Working |
| REQUEST Lambda authorizers (`x-amazon-apigateway-authorizer`), identity source enforced, `context` + `principalId` in `requestContext.authorizer` | Working |
| Missing identity source → 401 | Working (matches AWS) |
| Unknown route → 403 `Missing Authentication Token` | Working (matches AWS) |
| Authorizer **Deny** | **401**; AWS returns 403 → [#190](https://github.com/kgz/awsl/issues/190) |
| Custom domain + base-path mapping | Control plane only (needs `route53,acm` in SERVICES); requests aren't routed by domain → [#191](https://github.com/kgz/awsl/issues/191) |
| Console | HTTP APIs only → [#189](https://github.com/kgz/awsl/issues/189) |

## Calling a stage

```text
http://127.0.0.1:4566/restapis/<api-id>/<stage>/_user_request_/<path>
```

## Gotchas

- An authorizer sees headers in their original case (`Authorization`), as in AWS. Check both spellings if you lower-case elsewhere.
- Grant API Gateway `lambda:InvokeFunction` on each function (`add-permission`), as AWS requires. The smoke does.
