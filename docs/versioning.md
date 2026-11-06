# Versioning (product release vs pillars)

Two axes. Do not collapse them.

| Axis | Mechanism | Meaning |
|------|-----------|---------|
| **Pillar** | GitHub **milestone** (`Platform`, `Identity & authz`, …) | Category / workstream. See [version-plan.md](version-plan.md#pillars). |
| **Product release** | Issue **label** matching semver (`v0.0.2`) + git **tag** / GitHub Release | Which product cut the ticket belongs to. |

Current open cut: see [CURRENT_RELEASE](CURRENT_RELEASE).

**Roadmap:** [version-plan.md](version-plan.md).

| Cut | Theme |
|-----|--------|
| **v0.0.1** | Baseline account (historical). |
| **v0.0.2** | **Public** — install, docs-site, public hygiene (`public-ready`). |
| **v0.0.3** | **Trust** — core-stack bugs + security/authz (false confidence). Impact ≥ 4. |
| **v0.0.4** | **Accuracy** — core Debt/docs/smoke/console depth on shipped services. Impact ≥ 3. |
| **v0.1.0** | **Org path** — Transfer→…→RDS learning/staging path. |

Far-future width (`v0.1.1`, `v0.1.2`, `v1.0.0`) is **not** an active planning label — leave work **unlabelled** until that cut is deliberately opened.

Out-of-footprint / catalogue-width work stays **unlabelled** — milestone only.

## Scoring (Impact + Effort)

Every new ticket gets Project #8 number fields **Impact** (1–5) and **Effort** (1–5). See [version-plan.md](version-plan.md#scoring).

```bash
./bin/issue-score.sh <issue> --impact=N --effort=N
```

Work order inside a cut: Impact desc, then Effort asc.  
`priority_key = Impact * 10 - Effort` is for ordering only — **not** for auto-evicting tickets from a cut.

## Freeze (required for every new ticket)

No new open issue without:

1. A **pillar** milestone (see [version-plan.md](version-plan.md#pillars))
2. **Impact** + **Effort** via `./bin/issue-score.sh`
3. A **release label only** if theme + Impact gate match (below); otherwise **no version label**

Agents must not create unlabelled-for-pillar or unscored tickets. Unlabelled-for-version is correct for backlog width.

## New tickets

1. Assign the right **pillar** milestone.
2. Set **Impact** + **Effort** (`./bin/issue-score.sh`).
3. Add a **release label only** if the ticket matches an open cut’s theme + Impact gate (below). Otherwise **no version label**.
4. Board + tracker as usual (`./bin/board-status.sh`, `bin/board-tracker.tsv`).

### When to add a release label

| Cut | Add label if… |
|-----|----------------|
| `v0.0.2` | Blocks public OSS (`public-ready` or equivalent). |
| `v0.0.3` | Core-stack bug/authz with Impact ≥ 4 (Impact 5 always). |
| `v0.0.4` | Core Debt/docs/accuracy with Impact ≥ 3. |
| `v0.1.0` | Org-path critical. |

**Do not** default new / Debt tickets to `$(cat docs/CURRENT_RELEASE)`.

**Evaluate and place** — score, pick the matching cut (or none), stop. Do **not** bump other tickets out of a cut when filing Debt.

**In progress / in review:** keep the card’s release label if it has one; do not force `CURRENT_RELEASE` onto unlabelled backlog work. If it already has a planning cut label and you start it, leave that label (or move to `CURRENT_RELEASE` only when the card is intentionally pulled into the active cut).

## Debt / gap follow-ups

See [gap-check.md](gap-check.md). Prefer absorbing small additive gaps into the parent PR. If filing Debt: score + pillar always; release label only if the gate matches.

## Soft WIP

If an open cut grows past ~15 labelled issues, run a deliberate demote pass (lowest Impact, then highest Effort → next cut or unlabelled). Never as a side effect of `gh issue create`.

## Board views

Project #8 should keep a view per active cut plus triage views. Filters/sorts: [version-plan.md](version-plan.md#board-views).

## Cut a release

```bash
./bin/release-tag.sh v0.0.3
```

That script:

1. Tags `origin/main` (or `RELEASE_SHA`) as the version
2. Creates a GitHub Release
3. Ensures the label exists
4. Writes `docs/CURRENT_RELEASE`

Do not cut a public GitHub Release while open Impact ≥ 5 core trust bugs are unwaived.
