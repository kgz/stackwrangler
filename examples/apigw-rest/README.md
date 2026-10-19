# REST API (v1) from an OpenAPI document

A REST API imported from `openapi.template.json` with:

- `GET /public/callback`: no authorizer (e.g. an OAuth redirect target), `aws_proxy` to `handler.js`
- `GET /v1/items`: REQUEST Lambda authorizer (`authorizer.js`, allows `Authorization: Bearer good`), `aws_proxy` to `handler.js`

`${AUTHORIZER_URI}` and `${HANDLER_URI}` are filled in by the smoke with Lambda invocation URIs.

```bash
./bin/apigw-rest-smoke.sh
```

Invoke URL: `http://127.0.0.1:4566/restapis/<api-id>/<stage>/_user_request_/<path>`. See [docs/apigw-rest.md](../../docs/apigw-rest.md).
