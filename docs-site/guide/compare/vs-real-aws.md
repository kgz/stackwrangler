# vs real AWS

A real sandbox or shared-dev account is the advice AIs give most often. It is also the right **destination** after local staging — not a substitute for a local account while you break IAM and networking.

## Choose a real AWS account if

- You need managed-service behaviour we do not emulate (edge CDN, real quotas, production-scale load)
- Final pre-prod validation against the real control and data planes
- Billing and shared-account risk are acceptable for the team

## Choose stackwrangler (then promote) if

- You want fast iteration without a cloud bill or shared-account collisions
- Wrong IAM / SG / secret should fail **locally** before anyone pays for the mistake
- Multiple tools (CLI, console, OpenTofu, mobile client) must hit one local account
- You reset and rebuild often

## What stays the same

- API / SDK / IaC shapes
- Profile and endpoint wiring patterns (local → real by changing credentials / endpoints)
- Authz intent: workload roles that deny here should deny there for paths we smoke

## What does not

| | Local stackwrangler | Real AWS |
|--|---------------------|----------|
| Cost | Laptop resources | Bill + quotas |
| Isolation | Your machine | Account / org boundaries |
| Fidelity | Honest Working / Partial / Stub | Full managed behaviour |
| Network publish | Host ports on `127.0.0.1` by default | Public / VPC as designed |

## Spine

Same *shape* as a real account for the paths we cover — including **IAM that denies** (not default-allow) — then promote credentials to real AWS when ready.

Next: [Compare index](./) · [Getting Started](../getting-started) · [Use case](../use-cases/opentofu-expo-iam)
