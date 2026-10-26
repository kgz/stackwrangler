# apigw-authz slice

REQUEST Lambda authorizer that reads `Authorization`: `Bearer good` → Allow, anything else → explicit Deny, missing header → 401 (identity source). Public `GET /public/callback` has no authorizer.

Reference `serverless.yml` shows the Serverless Framework v3 shape; the smoke builds the same API from `openapi.template.json` with the AWS CLI (no `serverless deploy`).

```bash
./bin/apigw-rest-smoke.sh
```

Allow 200 (authorizer context reaches the handler), Deny 403 `User is not authorized to access this resource`, no header 401. See [docs/apigw-rest.md](../../../../docs/apigw-rest.md).
