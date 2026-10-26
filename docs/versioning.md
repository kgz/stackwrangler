# Versioning (product release vs milestones)

Two axes. Do not collapse them.

| Axis | Mechanism | Meaning |
|------|-----------|---------|
| **Service catalogue** | GitHub **milestone** `v1 — Networking`, `v1 — Data stores`, … | Workstream / depth for that area. Keep these names. |
| **Product release** | Issue **label** matching semver (`v0.0.1`) + git **tag** / GitHub Release | Which product cut the ticket belongs to. |

Current open cut: see [CURRENT_RELEASE](CURRENT_RELEASE) (today `v0.0.2`).

Historical mapping: **closed** work at the first tag is **`v0.0.1`**. Milestone titles stay `v1 — …`; the product version is the label + tag.

| Cut | Meaning |
|-----|---------|
| **v0.0.1** | First tagged baseline (`git tag v0.0.1`). Closed issues stay here. Shipped baseline; open cut is `v0.0.2`. |
| **v0.0.2** | **Console / UI** for shipped services (create/detail/wizards) **plus bugs** (incorrect AWS behaviour, authz holes, broken data-plane). Not for new service catalogue or fidelity epics. |
| **v0.0.3** | Later catalogue only (FinOps, AI, analytics, enterprise net, niche stubs, Code*, exotic DBs) and real-account mirror/parity. Do not label beyond this — unlabelled backlog stays unplanned. |

## New tickets

1. Assign the right **milestone** (`v1 — <area>`).
2. Add the label from `docs/CURRENT_RELEASE` (e.g. `v0.0.1`).
3. Board + tracker as usual (`./bin/board-status.sh`, `bin/board-tracker.tsv`).

Debt tickets inherit the parent's milestone **and** the current release label (or the parent's release label if filing from an older cut).

**In progress / in review** always use `docs/CURRENT_RELEASE` (strip other `v0.0.x` labels). Planning labels `v0.0.2` / `v0.0.3` are for backlog / ready only until the card moves into active work.

## Cut a release

```bash
./bin/release-tag.sh v0.0.2
```

That script:

1. Tags `origin/main` (or `RELEASE_SHA`) as `v0.0.2`
2. Creates a GitHub Release
3. Ensures label `v0.0.2` exists
4. Writes `docs/CURRENT_RELEASE` → `v0.0.2`

New tickets after that cut get `v0.0.2`. Older tickets keep their existing release label unless you deliberately retarget them.

Filter the board / issue list by label `v0.0.1` to see everything in that product bucket.
