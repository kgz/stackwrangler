## Context

Probe (2026-10-20, LocalEmu latest): `import-rest-api` with an OpenAPI 3 body, `aws_proxy` integrations and `x-amazon-apigateway-authorizer` (type `request`) works end to end. Differences from AWS: an authorizer Deny returns 401 (AWS 403). `create-domain-name` fails until `route53` is enabled; with it, domains and base-path mappings are created, but requests aren't routed by `Host` (they reach S3).

## Decisions

- **Prove, don't build.** The emulator already does the work; the deliverable is a repeatable smoke, a generic example and honest docs. Gaps become Debt tickets instead of emulator patches.
- **Template substitution in the smoke**, not a build step: `${AUTHORIZER_URI}` / `${HANDLER_URI}` replaced with Lambda invocation URIs at run time.
- **Assert current behaviour for known gaps** (Deny → 401) with the AWS value in the label, so the smoke turns red if the emulator changes and the Debt ticket can be closed.
- **Grant `lambda:InvokeFunction` to API Gateway** in the smoke even though the emulator doesn't require it, to match what real stacks must do.

## Risks

- LocalEmu `latest` can change behaviour; the smoke pins assertions so a change is visible.
