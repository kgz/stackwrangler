# Vision

Living product north star. Source of truth: [`docs/vision.md`](https://github.com/kgz/stackwrangler/blob/main/docs/vision.md) in the repo — update that file when the destination shifts; keep this page aligned. Named **stackwrangler** throughout.

**Not affiliated with Amazon Web Services.** stackwrangler is independent OSS: build on LocalEmu and related sidecars, test locally, then deploy to real AWS. It is not an AWS product and not a hosted AWS substitute. See [LICENSE](https://github.com/kgz/stackwrangler/blob/main/LICENSE) and [THIRD_PARTY.md](https://github.com/kgz/stackwrangler/blob/main/THIRD_PARTY.md).

## Feel

**One local AWS-shaped account** that speaks the real AWS API. Console, CLI, and **IaC** (Terraform / CDK / SAM / Ansible / Pulumi) talk to that same account.

**Bar: fully working, not catalogue theatre.** Create → configure → traffic/data moves → you can see it in CLI + console. If a hop only returns JSON and never does work, it is unfinished.

**Authz must match AWS locally.** Whatever would deny or fail in a real account — missing/wrong identity policy, resource policy, trust/assume-role, condition keys, cross-service call under a task/execution role — must deny or fail here too (`AccessDenied` / equivalent), not silently succeed. Root / stackwrangler keys admin the box; **workload principals** are enforced (`IAM_ENFORCEMENT=1` on LocalEmu). The S3 deny-user lab is only one proof; the rule is general across services on the path.

Learning target: a large org can tell a developer “implement X” (e.g. VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS) and they can **run that stack locally** — including failing for the same mistakes as AWS — before touching a real account.

End state: `./bin/stackwrangler up` once — endpoints + profile `local` — then real apps run on that account.

## What “fully working” means

| Depth | Meaning | Product status |
|-------|---------|----------------|
| **Data plane** | Real storage, invoke, containers, queues, DB connections, (eventually) SFTP bytes | **Done** for that service |
| **Authz plane** | Same deny/allow outcomes as AWS for workload identities + resource policies | **Required** alongside data plane |
| **Settings / topology fidelity** | Same *defaults and obscure knobs* as AWS — SG rules, awsvpc hairpin/NAT, target-group stickiness, IAM condition keys, retention/TTL, proxy behaviour when two tasks share a host | **Plan now; deepen after org-path data+authz** — not v1 catalogue width |
| **Control plane only** | `create-*` / `describe-*` succeed; no real traffic | **Stub** — document limits; not “shipped” for org paths |
| **Console empty** | Nav chrome, honest “not on local stack yet” | UX only |

**Priority rule:** prefer deepening data planes **and** IAM enforcement on the org path over adding more stub APIs. Stubs exist so IaC can *start* applying; they are debt, not the destination.

Smoke pattern for each hop: happy path **and** at least one deliberate authz failure (not a single hard-coded policy demo).

**Fidelity bar (raise continuously):** if a real account fails because of a network path, default, or setting you “wouldn’t think of” (e.g. two ECS tasks on the same host cannot hairpin through a NAT/proxy without the right IP retention / routing), stackwrangler should be able to reproduce that class of failure — not only happy CRUD. Capture gaps as concrete follow-ups with a repro; do not wait for a full AWS clone before writing them down. See [docs/fidelity.md](https://github.com/kgz/stackwrangler/blob/main/docs/fidelity.md) in the repo.

### Already real (keep raising the bar)

- **S3** — objects (SeaweedFS UI + LocalEmu for IaC/events)
- **Lambda** — Docker invokes that write/read
- **ECS / EC2** — container-backed tasks/instances
- **IAM / STS** — enforcement on; lab proves one path; every service smoke should cover authz under its real principal
- **CFN / CDK / SAM / Terraform** — deploy against the same account

### Must become real for the SFTP org path

Transfer (actual SFTP), VPC wiring that matters, Lambda triggers, S3, ECS, **RDS** — each hop must pass a smoke that moves data, not only creates resources.

## What “done” looks like for you

```text
./bin/stackwrangler up
# apply your Serverless / CDK / TF / Ansible against profile local
# put a file through SFTP (or the path under test)
# Lambda runs, object lands, ECS task runs, RDS has the row
aws --profile local …   # same resources
./bin/stackwrangler console     # same resources
```

## Architecture note

| Surface | Backend today |
|---------|----------------|
| Console **General purpose buckets** UI | SeaweedFS `:8333` |
| IAM / Lambda / Logs / API GW / CFN / Transfer / **IaC S3** | LocalEmu `:4566` |

S3 ↔ Lambda “actually do things” must use **one** S3 backend → **LocalEmu S3**. SeaweedFS stays the polished buckets page until/unless we unify.

LocalEmu is the emulator; **stackwrangler** is the product (compose, profile, console, smokes, examples, honesty about depth). Not Cloudflare Wrangler.

### Architecture map (intent)

A live topology / architecture-map surface in the console is part of the north star: see how services connect on the local account the same way you reason about a real account. Tracked as [#389](https://github.com/kgz/stackwrangler/issues/389) (experimental; not required for first public cut). Until it ships, [Completeness](./completeness) and the [interactions catalog](./interactions/) carry the hosting footprint and cross-service edges.

## LocalStack lesson (do not repeat)

Orgs often tried **LocalStack** for full local repro and got a false green:

- **Community IAM** largely does not enforce → missing policies still “succeed”
- **Control plane ≠ data plane** → resources exist; traffic/authz does not
- **Pro-gated / partial services** → catalogue looks wide; depth is uneven
- **Endpoint sprawl** → easy to point CLI/console/Lambda at different S3 brains

**stackwrangler refusal:** never market a service as ready because `create-*` works. Prefer LocalEmu (`IAM_ENFORCEMENT=1`) and **real sidecars** when the emulator cannot deliver a data plane (e.g. Postgres for RDS-shaped work, real SFTP listener if Transfer stays API-only). Swap emulators if needed — the product contract is the account behaviour, not the vendor logo.

### Honest limits of the vision

| Risk | Mitigation |
|------|------------|
| “Authz must match AWS” is absolute — full IAM/condition/SCP parity is rare | Claim **parity on smokes we ship**; document known gaps; expand smoke corpus |
| Huge backlog of stub tickets recreates catalogue theatre | Execution order = org path data plane; stubs stay labeled stub |
| Dual S3 (SeaweedFS vs LocalEmu) | **Keep split for now** — see [Concepts](./concepts); IaC/runtime LocalEmu; console/`local` SeaweedFS |
| Emulator ceiling (no real SFTP/RDS/…) | Sidecar or custom bridge; don’t pretend |

## How we prioritize

1. **Org path first** — Transfer data plane, RDS, VPC as needed, ECS/EC2 console, then one E2E smoke across the path.
2. **Messaging / data that runs** — SQS, SNS, EventBridge, DynamoDB with real send/receive/query smokes before FinOps/AI stubs.
3. **Stubs only when** LocalEmu has no data plane *and* IaC still needs the resource type — label them stub; promote when real.
4. **Do not call a service done** because `list-*` returns 200.

Catalogue milestones are orthogonal to depth: **execution order follows data-plane value**, not milestone number. Live Working / Partial / Backlog: [Completeness](./completeness).

**Shipped so far (high level):** S3 UI, IAM, Lambda, Logs, API GW, Terraform/CFN/CDK/SAM S3+Lambda, ECS/EC2 samples, Transfer API + native SFTP SSH keys → S3, RDS Docker Postgres / MySQL paths. Details and gaps stay on Completeness.

```bash
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

## What goes where

| Thing | Home |
|-------|------|
| This north star (repo) | `docs/vision.md` |
| This page (public) | `docs-site/guide/vision.md` |
| Depth / status | [Completeness](./completeness) |
| Cross-service edges | [Interactions](./interactions/) |
| Console mocks (design) | `design/awsbox-console/` |
| IaC examples | `examples/` |
| Product entry | `./bin/stackwrangler` |
