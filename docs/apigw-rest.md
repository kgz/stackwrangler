# API Gateway REST APIs (v1)

REST APIs imported from an OpenAPI 3 document with `x-amazon-apigateway-*` extensions, the shape spec-first stacks (Serverless `resources`, CloudFormation `AWS::ApiGateway::RestApi` `Body`) deploy.

Example / slice: [examples/serverless-v3-rest/slices/apigw-authz](../examples/serverless-v3-rest/slices/apigw-authz/) · Smoke: `./smokes/apigw/apigw-rest-smoke.sh` · Real (Deny 403 + API keys, cents): `./smokes/parity/aws-parity-hf-cheap.sh` ([aws-parity-hf-cheap.md](aws-parity-hf-cheap.md))

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
| `HTTP_PROXY` request body | Working. Raw body is forwarded (including curl `-d` default `application/x-www-form-urlencoded`). Smoke: `./smokes/apigw/apigw-proxy-body-smoke.sh`. |
| `HTTP_PROXY` + `VPC_LINK` to an internal NLB | Working. NLB DNS resolves inside LocalEmu; TCP listeners forward to ip/instance targets ([docs/elbv2.md](elbv2.md)). Smoke: `./smokes/apigw/apigw-nlb-ecs-smoke.sh` phase A. |
| API keys + usage plans | Working: `x-api-key` (`apiKeySource` HEADER) or authorizer `usageIdentifierKey` (AUTHORIZER); missing / unknown / disabled / revoked key → 403; plan throttle and quota → 429. [Details](#api-keys-and-usage-plans) |
| Console | REST APIs list + create/deploy + resource/method ([#543](https://github.com/kgz/stackwrangler/issues/543), from [#189](https://github.com/kgz/awsl/issues/189)) · authorizer/Actions [#612](https://github.com/kgz/stackwrangler/issues/612) · API keys / usage plans [#310](https://github.com/kgz/awsl/issues/310) · shot [#613](https://github.com/kgz/stackwrangler/issues/613) |
| Console | REST APIs list + create/deploy + resource/method ([#543](https://github.com/kgz/stackwrangler/issues/543), from [#189](https://github.com/kgz/awsl/issues/189)) · method integration picker MOCK / Lambda `AWS_PROXY` / `HTTP_PROXY` ([#616](https://github.com/kgz/stackwrangler/issues/616)) · authorizer/Actions [#612](https://github.com/kgz/stackwrangler/issues/612) · API keys / usage plans [#310](https://github.com/kgz/awsl/issues/310) · shot [#613](https://github.com/kgz/stackwrangler/issues/613) |

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
./smokes/apigw/apigw-nlb-ecs-smoke.sh
```

`create-vpc-link` + `put-integration --connection-type VPC_LINK --connection-id …` with
`uri http://<nlb-dns>:80/...` forwards through the ELBv2 TCP listener to registered targets.
NLB DNS is published into LocalEmu `/etc/hosts` (and `.awsbox/elbv2.hosts`); the invoke path also
rewrites `*.elb.amazonaws.com` to the listener bind address
(`localemu-patches/init/start.d/20-apigw-vpc-link.py`).

Stopped or unhealthy targets return 5xx on invoke (AWS: 504 / 503).

`describe-tasks` ENI IPs that sit outside the subnet CIDR are [#268](https://github.com/kgz/awsl/issues/268);
the smoke registers the container's VPC-bridge address in that case so phase A still covers the NLB path.

## API keys and usage plans

Example: [examples/serverless-v3-rest/slices/api-keys](../examples/serverless-v3-rest/slices/api-keys/) · Smoke: `./smokes/apigw/apigw-usage-plan-smoke.sh`

Per-client keys minted at runtime by a Lambda (`CreateApiKey` + `CreateUsagePlanKey`, plan found by name with `GetUsagePlans`, revoked with `DeleteApiKey`) work as in AWS:

| Request | Result |
|---------|--------|
| Method with `apiKeyRequired`, valid enabled key in a plan for the stage | 200 |
| No key, unknown key, disabled key, key not in a plan for the stage | 403 `Forbidden` |
| Key deleted with `DeleteApiKey` (also removed from its plans) | 403 |
| Past the plan `throttle` (token bucket per key: `rateLimit`, `burstLimit`) | 429 `Too Many Requests` |
| Past the plan `quota` (`limit` per UTC `DAY`, `WEEK` starting Sunday, or `MONTH` starting on the 1st; `offset` is subtracted from the limit in the first period) | 429 `Limit Exceeded` |

Throttled requests do not count against the quota. With `apiKeySource` AUTHORIZER the key is the authorizer's `usageIdentifierKey`; `x-api-key` is ignored.

IAM follows AWS: every API Gateway management call (v1 and v2) is `apigateway:<HTTP verb>` on `arn:aws:apigateway:<region>::/<path>` (for example `POST` on `/apikeys`, `GET` on `/usageplans/<id>/keys`, `DELETE` on `/apikeys/<id>`). `apigateway:CreateApiKey`-style action names no longer match. Smoked for keys and usage plans only → [#311](https://github.com/kgz/awsl/issues/311).

Limitations: limits come from the plan only (no per-stage / per-method `apiStages[].throttle`), counters are in memory and reset on restart, and `get-usage` / `update-usage` are not wired to them → [#309](https://github.com/kgz/awsl/issues/309). No console → [#310](https://github.com/kgz/awsl/issues/310).

Enforcement lives in `localemu-patches/init/start.d/20-apigw-usage-plans.py` and `20-apigw-iam.py`.

## Gotchas

- An authorizer sees headers in their original case (`Authorization`), as in AWS. Check both spellings if you lower-case elsewhere.
- Grant API Gateway `lambda:InvokeFunction` on each function (`add-permission`), as AWS requires. The smoke does.
- HTTP_PROXY must not re-encode `application/x-www-form-urlencoded` bodies (`localemu-patches/init/start.d/20-apigw-proxy-body.py`).
