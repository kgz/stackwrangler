# Lambda → Secrets Manager → OAuth HTTP

Function reads a secret, exchanges credentials for an OAuth token, POSTs to an external mock. Stage isolation for secrets. Role without `GetSecretValue` → mock sees no requests. Bad client secret → 401, no document posted.

**Status:** shipped

## Sequence

1. Store client credentials in Secrets Manager.
2. Lambda `GetSecretValue` → token endpoint → API call.
3. Sad: missing secret permission; wrong secret value.

## Prove it

```bash
./smokes/lambda/lambda-secret-oauth-smoke.sh
```
