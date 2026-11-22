# Org learning / staging path

Target chain for **v0.1.0**:

**VPC → Transfer Family (SFTP) → Lambda → S3 → ECS → RDS**

Epic [#90](https://github.com/kgz/stackwrangler/issues/90) · path [#91](https://github.com/kgz/stackwrangler/issues/91). Ship bar: [version-plan.md](version-plan.md) (`v0.1.0`). Public narrative: [docs-site use case](../docs-site/guide/use-cases/org-path.md).

**Overall today: Partial.** Hop smokes exist. One applyable example + full-chain E2E smoke are **in cut**, not on `main` yet — do not claim Working.

| Deliverable | Status | Track |
|-------------|--------|--------|
| Terraform example (stranger apply) | coming in cut | [#780](https://github.com/kgz/stackwrangler/issues/780) |
| E2E smoke (SFTP → … → RDS row) | coming in cut | [#781](https://github.com/kgz/stackwrangler/issues/781) |
| This doc + status honesty | this page | [#782](https://github.com/kgz/stackwrangler/issues/782) |
| Single S3 brain / non-silent switch | required for honest ship bar | [#162](https://github.com/kgz/stackwrangler/issues/162) |

## Host / ports (Linux-first)

After `./bin/stackwrangler up` on a Linux Docker host:

| What | Address |
|------|---------|
| LocalEmu (Transfer API, Lambda, IaC S3, RDS API, …) | `http://127.0.0.1:4566` |
| SeaweedFS (console / `aws --profile local` S3) | `http://127.0.0.1:8333` |
| Transfer SFTP (native) | `127.0.0.1:2222` ([transfer.md](transfer.md)) |
| Console | `http://127.0.0.1:3000` |

Published ports bind to `127.0.0.1` on the Docker host. Windows users: run Linux via WSL (or an engine inside WSL); see [docker-install.md](docker-install.md).

## Real vs stub (data plane)

Honest map of what moves bytes today vs control-plane / sidecar / still open. Status tags match [status.md](status.md).

| Hop | Data plane today | Notes / gaps |
|-----|------------------|--------------|
| **VPC / SG** | **Partial** | Create/describe + enforcement smokes; topology fidelity still deepening |
| **Transfer control plane** | **Partial** | `create-server` / `create-user` / `ImportSshPublicKey` on LocalEmu |
| **Transfer SFTP → object** | **Partial** · **Sidecar-shaped native listen** | SSH public keys only → Put under Transfer role into **LocalEmu S3** (`:4566`). Empty-role put denied (`transfer-authz-smoke.sh`). LOGICAL / custom IdP / password **N/A** (honest refuse — [docs/transfer.md](transfer.md)). Console user/key → [#321](https://github.com/kgz/stackwrangler/issues/321) |
| **Lambda** | **Working** (invoke) | ObjectCreated / path wiring is hop-smoked with Transfer; full path chain → [#781](https://github.com/kgz/stackwrangler/issues/781) |
| **S3** | **Partial** (dual brain) | Path / IaC / events → LocalEmu `:4566`. Console + `aws --profile local` → SeaweedFS `:8333`. See [Dual S3](#dual-s3--post-162) |
| **ECS task** | **Partial** | Docker tasks + ECR pull smokes; console Run/service depth still Debt |
| **RDS SQL** | **Partial** · **Sidecar** | Postgres/MySQL Docker DBs; create + SQL smokes. Aurora failover / some TF edges still open |

Stubs that are **not** on this path’s happy claim: Transfer FTPS/FTP, AS2 retrieve polish, hosting-company multi-tenant product (`v1.0.0`).

Per-edge catalog pages (hop-level, not the full chain):

- [Transfer SFTP → S3](../docs-site/guide/interactions/transfer-sftp-s3.md)
- [Dual S3](../docs-site/guide/interactions/dual-s3.md)
- [ECS → ECR](../docs-site/guide/interactions/ecs-ecr-pull.md)
- [RDS create → SQL](../docs-site/guide/interactions/rds-create-sql.md)

## Dual S3 / post-#162

Today the split is intentional and smoked ([s3-backends.md](s3-backends.md)):

| Brain | Endpoint | Who |
|-------|----------|-----|
| SeaweedFS | `:8333` | Console buckets, `aws --profile local` |
| LocalEmu S3 | `:4566` | Lambda, Transfer home, CFN/CDK/TF, S3 events |

Putting a file through Transfer lands in **LocalEmu S3**. Looking only at the console bucket list (SeaweedFS) will **not** show that object — that is the dual-brain trap.

**v0.1.0 ship bar** requires the org path to use **one** brain for Transfer/Lambda/IaC **and** what console / `aws --profile local` show for that path — either unify or an explicit non-silent switch. That work is [#162](https://github.com/kgz/stackwrangler/issues/162). Until it lands, docs and smokes must name which store they assert; silent cross-wire fails the cut.

Prove the current split:

```bash
./smokes/s3/s3-dual-endpoint-smoke.sh
```

## How to exercise today (hops)

No single org-path example or E2E script on `main` yet. Use hop smokes after `up`:

```bash
./bin/stackwrangler up

# Transfer: control plane + SSH key put → LocalEmu S3 (+ Lambda on key smoke)
./smokes/transfer/transfer-smoke.sh
./smokes/transfer/transfer-key-smoke.sh
./smokes/transfer/transfer-dataplane-smoke.sh

# Compute / data hops used by the path
./smokes/lambda/lambda-smoke.sh
./smokes/compute/ecr-smoke.sh
./smokes/data/rds-smoke.sh
```

Canonical names and sad/authz columns: [smoke-matrix.md](smoke-matrix.md) · [test-paths.md](test-paths.md). Transfer detail: [transfer.md](transfer.md).

Keep Transfer fixtures: `AWSBOX_TRANSFER_KEEP=1` / `STACKWRANGLER_TRANSFER_KEEP=1` (see Transfer smoke headers).

Existing thin sample (not the full org chain): [examples/transfer/sftp-s3](../examples/transfer/sftp-s3/).

## Coming in cut (do not invent yet)

When [#780](https://github.com/kgz/stackwrangler/issues/780) and [#781](https://github.com/kgz/stackwrangler/issues/781) merge, expect roughly:

1. `./bin/stackwrangler up`
2. Apply the example under `examples/` (README in that tree)
3. SFTP put to `127.0.0.1:2222`
4. `./smokes/…/org-path-smoke.sh` (exact path from #781) exit 0 — Lambda ran, object in the **path** S3 brain, ECS ran, RDS has the row
5. Console deep-links only where UIs exist; disabled controls stay `title="To implement"`

Until then: point learners at this page + hop smokes; status row stays **Partial** / E2E **Backlog** → [#781](https://github.com/kgz/stackwrangler/issues/781).

## Related

- [status.md](status.md) — Org staging table
- [version-plan.md](version-plan.md) / [versioning.md](versioning.md) — cut ship bar
- [s3-backends.md](s3-backends.md) · [#162](https://github.com/kgz/stackwrangler/issues/162)
- [transfer.md](transfer.md) · [rds.md](rds.md)
- Completeness (public): [docs-site/guide/completeness.md](../docs-site/guide/completeness.md)
