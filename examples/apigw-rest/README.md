# REST API (v1) from an OpenAPI document

Replication slice (authorizer Allow / Deny / missing header + OpenAPI template):
[examples/serverless-v3-rest/slices/apigw-authz](../serverless-v3-rest/slices/apigw-authz/).

This directory keeps the same handler / authorizer / OpenAPI stubs for older links.

```bash
./bin/apigw-rest-smoke.sh
```

Invoke URL: `http://127.0.0.1:4566/restapis/<api-id>/<stage>/_user_request_/<path>`. A custom domain `Host` (or local DNS) uses `/<base-path>/<path>`. See [docs/apigw-rest.md](../../docs/apigw-rest.md).
