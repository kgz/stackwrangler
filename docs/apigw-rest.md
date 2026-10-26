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
| Authorizer **Deny** | Working (403 `User is not authorized to access this resource`, matches AWS) |
| Custom domain + base-path mapping | Working. `Host` (or DNS pointed at the edge) reaches the mapped API/stage. Needs `route53,acm` in SERVICES to create the domain. |
| `HTTP_PROXY` + `VPC_LINK` to an internal NLB | Working. NLB DNS resolves inside LocalEmu; TCP listeners forward to ip/instance targets ([docs/elbv2.md](elbv2.md)). Smoke: `./bin/apigw-nlb-ecs-smoke.sh` phase A. |
| Console | HTTP APIs only → [#189](https://github.com/kgz/awsl/issues/189) |

## Calling a stage

```text
http://127.0.0.1:4566/restapis/<api-id>/<stage>/_user_request_/<path>
```

Custom domain (`create-domain-name` + `create-base-path-mapping`). Point the name at the edge with a `Host` header or local DNS (`curl --resolve name:4566:127.0.0.1`):

```text
http://<domain>/<path>                    base path (none) — root mapping
http://<domain>/<base-path>/<path>        named mapping; the base path is stripped before the route is matched
```

The longest matching base path wins. `(none)` catches every other path on that host. A prefix that matches nothing, and no root mapping, returns **403** `{"message":"Forbidden"}`.

Routing lives in `localemu-patches/init/start.d/20-apigw-custom-domain.py`.

## VPC link → NLB

```bash
./bin/apigw-nlb-ecs-smoke.sh
```

`create-vpc-link` + `put-integration --connection-type VPC_LINK --connection-id …` with
`uri http://<nlb-dns>:80/...` forwards through the ELBv2 TCP listener to registered targets.
NLB DNS is published into LocalEmu `/etc/hosts` (and `.awsbox/elbv2.hosts`); the invoke path also
rewrites `*.elb.amazonaws.com` to the listener bind address
(`localemu-patches/init/start.d/20-apigw-vpc-link.py`).

Stopped or unhealthy targets return 5xx on invoke (AWS: 504 / 503).

`describe-tasks` ENI IPs that sit outside the subnet CIDR are [#268](https://github.com/kgz/awsl/issues/268);
the smoke registers the container's VPC-bridge address in that case so phase A still covers the NLB path.

## Gotchas

- An authorizer sees headers in their original case (`Authorization`), as in AWS. Check both spellings if you lower-case elsewhere.
- Grant API Gateway `lambda:InvokeFunction` on each function (`add-permission`), as AWS requires. The smoke does.
