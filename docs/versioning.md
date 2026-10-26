# Versioning (product release vs milestones)

Two axes. Do not collapse them.

| Axis | Mechanism | Meaning |
|------|-----------|---------|
| **Service catalogue** | GitHub **milestone** `v1 — Networking`, `v1 — Data stores`, … | Workstream / depth for that area. Keep these names. |
| **Product release** | Issue **label** matching semver (`v0.0.1`) + git **tag** / GitHub Release | Which product cut the ticket belongs to. |

Current open cut: see [CURRENT_RELEASE](CURRENT_RELEASE).

**Full roadmap (what each cut includes):** [version-plan.md](version-plan.md) — IT/CRM hosting footprint → `v1.0.0`.

| Cut | Theme |
|-----|--------|
| **v0.0.1** | Baseline account (historical / closeout). |
| **v0.0.2** | Console UI for shipped services **+ bugs**. |
| **v0.0.3** | Hosting day-1 gaps (ElastiCache, SES, Cognito, Metrics/Alarms, SSM, edge/DNS/ACM polish). |
| **v0.1.0** | CRM org path (Transfer→…→RDS), dev-mode, S3 unify, Backup. |
| **v0.1.1** | Delivery + enterprise attach (Code*, CloudTrail, OpenSearch, DMS, TGW/VPN stubs). |
| **v0.1.2** | Account ops + real-account mirror / least-privilege tooling. |
| **v1.0.0** | Hosting-company ready declaration (in-scope Working/Partial + honest stubs). |

Out-of-footprint work (AI, niche, exotic DB, …) stays **unlabelled** — see version-plan.md.

## New tickets

1. Assign the right **milestone** (`v1 — <area>`).
2. Add the label from `docs/CURRENT_RELEASE` (or the planning cut from version-plan.md if backlog).
3. Board + tracker as usual (`./bin/board-status.sh`, `bin/board-tracker.tsv`).

Debt tickets inherit the parent's milestone **and** the parent's release label (or current release if filing from an older cut into active work).

**In progress / in review** always use `docs/CURRENT_RELEASE` (strip other `v0.0.x` / `v0.1.x` labels). Planning labels are for backlog / ready only until the card is active.

## Cut a release

```bash
./bin/release-tag.sh v0.0.3
```

That script:

1. Tags `origin/main` (or `RELEASE_SHA`) as the version
2. Creates a GitHub Release
3. Ensures the label exists
4. Writes `docs/CURRENT_RELEASE`

Filter the board / issue list by label to see everything in that product bucket.
