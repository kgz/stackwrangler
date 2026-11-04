# WAFv2 / WAF Classic (local)

LocalEmu `wafv2` (moto) + `waf` (classic list stub) on `:4566`.

**Control plane only.** Creating a WebACL and associating it to an API Gateway stage stores the association; **rule evaluation is not real edge WAF** — requests are not inspected or blocked by rate/managed rules.

## Smokes

```bash
./bin/stackwrangler up --force
./bin/waf-smoke.sh          # create WebACL + associate + get/list
./bin/waf-authz-smoke.sh    # deny CreateWebACL
```

## Profile

`./bin/stackwrangler up --force` writes profile `local`, which sends `wafv2` / `waf` to the LocalEmu endpoint.

## Slice

`examples/serverless-v3-rest/slices/waf/` — CFN shape (`AWS::WAFv2::WebACL`, `WebACLAssociation`, SSM ARN). Smoke applies the same shape via CLI (LocalEmu CFN has no WAFv2 resource providers yet — see Debt).

## Limits

| Area | Behaviour |
|------|-----------|
| Create / get / list WebACL | Working (moto) |
| Associate ↔ API GW stage | Working; `get-web-acl-for-resource` / `list-resources-for-web-acl` |
| Rule evaluation / edge block | **Not implemented** — [#326](https://github.com/kgz/awsl/issues/326) |
| WAF Classic | List stubs only (`ListWebACLs`, …) |
| Console | None → [#324](https://github.com/kgz/awsl/issues/324) |
| CFN `AWS::WAFv2::*` | Not in LocalEmu CFN providers → [#325](https://github.com/kgz/awsl/issues/325) |
