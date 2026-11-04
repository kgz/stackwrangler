# Vision

Living product north star (rewritten from [`docs/vision.md`](https://github.com/kgz/stackwrangler/blob/main/docs/vision.md) for humans). Update the repo file when the destination shifts; keep this page aligned.

**Not affiliated with Amazon Web Services.** Independent OSS — local test, then real AWS.

## Feel

**One local AWS-shaped account** that speaks the real AWS API. Console, CLI, and IaC (Terraform / CDK / SAM / Ansible / Pulumi) talk to that same account.

**Bar: fully working, not catalogue theatre.** Create → configure → traffic or data moves → you can see it in CLI and console. If a hop only returns JSON and never does work, it is unfinished.

**Authz must match AWS locally.** Missing or wrong identity policy, resource policy, trust / assume-role, or condition keys should deny here too (`AccessDenied` or equivalent), not silently succeed. Root / stackwrangler keys admin the box; **workload principals** are enforced (`IAM_ENFORCEMENT=1` on LocalEmu).

Learning target: a large org can tell a developer “implement X” (for example VPC → Transfer/SFTP → Lambda → S3 → ECS → RDS) and they can **run that stack locally** — including failing for the same mistakes as AWS — before touching a real account.

End state:

```text
./bin/stackwrangler up
# apply Serverless / CDK / TF / Ansible against profile local
# exercise the path under test
aws --profile local …
./bin/stackwrangler console
```

## What “fully working” means

| Depth | Meaning | Product status |
|-------|---------|----------------|
| **Data plane** | Real storage, invoke, containers, queues, DB connections, (eventually) SFTP bytes | **Done** for that service |
| **Authz plane** | Same deny/allow outcomes as AWS for workload identities + resource policies | **Required** with the data plane |
| **Settings / topology fidelity** | Obscure knobs and network defaults that bite on real AWS | Plan now; deepen after org-path data + authz |
| **Control plane only** | `create-*` / `describe-*` succeed; no real traffic | **Stub** — document limits |
| **Console empty** | Nav chrome, honest “not on local stack yet” | UX only |

**Priority:** deepen data planes **and** IAM enforcement on the org path before adding more stub APIs. Stubs exist so IaC can start applying; they are debt, not the destination.

## Already real (keep raising the bar)

- **S3** — objects (SeaweedFS UI + LocalEmu for IaC/events)
- **Lambda** — Docker invokes that write/read
- **ECS / EC2** — container-backed tasks/instances
- **IAM / STS** — enforcement on; every service smoke should cover authz under its real principal
- **CFN / CDK / SAM / Terraform** — deploy against the same account

## LocalStack lesson (do not repeat)

Orgs often tried LocalStack for full local repro and got a false green:

- Community IAM largely does not enforce → missing policies still “succeed”
- Control plane ≠ data plane → resources exist; traffic/authz does not
- Pro-gated / partial services → catalogue looks wide; depth is uneven
- Endpoint sprawl → easy to point CLI/console/Lambda at different S3 brains

**stackwrangler refusal:** never market a service as ready because `create-*` works. Prefer LocalEmu with IAM enforcement and **real sidecars** when the emulator cannot deliver a data plane. The product contract is account behaviour, not a vendor logo.

## Honest limits

| Risk | Mitigation |
|------|------------|
| Full IAM/condition/SCP parity is rare | Claim parity on **smokes we ship**; document gaps |
| Stub backlog recreates catalogue theatre | Org-path data plane first; stubs stay labelled stub |
| Dual S3 (SeaweedFS vs LocalEmu) | Intentional near-term — see [Concepts](./concepts) |
| Emulator ceiling (no real SFTP/RDS/…) | Sidecar or bridge; don’t pretend |

See also [Completeness](./completeness) for the hosting footprint map.
