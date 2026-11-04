# api-keys slice

REST API with `GET /v1/items` (`apiKeyRequired`, `x-api-key` header) and `GET /public/ping` (open), three usage plans (`standard`, `tight`, `capped`), and a token-admin Lambda that mints and revokes keys at runtime with CreateApiKey, CreateUsagePlanKey, GetUsagePlans and DeleteApiKey.

```bash
./smokes/apigw/apigw-usage-plan-smoke.sh
```

Behaviour and gaps: [docs/apigw-rest.md](../../../../docs/apigw-rest.md#api-keys-and-usage-plans).
