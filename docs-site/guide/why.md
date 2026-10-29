# Why stackwrangler

Orgs need a **local AWS-shaped account** that fails for the same reasons real AWS does — then the same CLI, console, and IaC can move to a real account without rewriting the stack.

## The problem

Teams stage cloud work on laptops and CI against emulators. Too often that is a **false green**:

- **IAM that does not enforce** — missing or wrong policies still “succeed”
- **Control plane ≠ data plane** — `create-*` returns 200; traffic, objects, and invokes never happen
- **Catalogue theatre** — a long service list with thin or Pro-gated depth
- **Endpoint sprawl** — CLI, console, and Lambda pointed at different S3 (or other) brains

You only discover the gap on real AWS: AccessDenied, empty buckets, tasks that cannot talk, SFTP that never lands an object.

## Who it is for

- Developers told “implement X” on a path like VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS and who need to **run that path locally** first
- Teams that want **one account** for console, `aws --profile local`, Terraform / CDK / SAM / Serverless — not three half-connected mocks
- Anyone tired of shipping against an emulator that lies about authz

## What we refuse

| Temptation | stackwrangler stance |
|------------|----------------------|
| Market `create-*` as shipped | Label **Control plane** / stub until data moves |
| Silent allow when a workload role is wrong | **AccessDenied** (or equivalent) under `IAM_ENFORCEMENT=1` |
| Fake SFTP / RDS with JSON only | Prefer a **sidecar** that moves real bytes |
| Hide Partial | README + [Completeness](./completeness) say Working / Partial / Backlog out loud |

LocalEmu is the emulator; **stackwrangler** is the product (compose, profile `local`, console, smokes, honesty about depth). Swap the emulator if needed — the contract is **account behaviour**, not a vendor logo.

## What “done” feels like

```text
./bin/stackwrangler up
# apply Serverless / CDK / TF against profile local
# exercise the path (file through SFTP, invoke, object, task, DB row)
aws --profile local …
./bin/stackwrangler console
# later: same shape → real AWS
```

Not affiliated with Amazon Web Services. Independent MIT-licensed OSS — local test, then real AWS.

Next: [Vision](./vision) (north star) · [Completeness](./completeness) (what exists / gaps / % depth) · [Getting Started](./getting-started).
