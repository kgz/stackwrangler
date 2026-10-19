## 1. Stack (#184)

- [x] 1.1 `route53,acm` in LocalEmu SERVICES; profile `local` endpoints

## 2. Example + smoke (#184)

- [x] 2.1 `examples/apigw-rest/` (OpenAPI template, handler, REQUEST authorizer, README)
- [x] 2.2 `bin/apigw-rest-smoke.sh` (happy: public, query, Allow + context, domain/mapping; sad: no token, Deny, unknown route)
- [x] 2.3 Wire into `bin/e2e.sh`

## 3. Docs (#184)

- [x] 3.1 `docs/apigw-rest.md`, smoke matrix, test paths, README row

## 4. Ship

- [x] 4.1 Gap check → Debt #189 (console), #190 (Deny 401/403), #191 (custom domain routing)
- [ ] 4.2 PR Closes #184; board in-review
