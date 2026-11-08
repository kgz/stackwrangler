# Post-ticket gap check (cheap)

Run **before** marking a ticket `done` / merging the PR. Goal: no half-baked CLI/UI ships without a tracked follow-up — prefer fixing small gaps in the same PR. Docs gaps use **Doc:** (or ship docs in the PR) — see [docs-catalog.md](docs-catalog.md).

```bash
./bin/gap-check.sh <issue-num>   # prints checklist + heuristic hits
```

## Absorb vs Debt (required)

Before filing `Debt:`, answer:

1. Can this be a **small additive AC** on the current ticket (same PR, same service)?
2. Is the resulting diff **small** (rough guide: Effort ≤ 2, localized, no new Open Design epic)?

If **yes to both** → implement in this ticket; extend AC; **no Debt issue**.

If **no** → file Debt, then **evaluate-and-place** (score + pillar; release label only if cut gate matches). Never auto-label with `$(cat docs/CURRENT_RELEASE)`.

**Anti-debt-loop:** After a console create/detail MVP, leftover stubs (delete, receive, put-targets, tags, Actions, …) are usually **unlabelled backlog**, not automatic members of the open cut. Reserve the release label for behaviour mismatch, false-confidence authz, missing smoke for shipped behaviour, or other cut-gate Impact hits — not every next chrome surface. See [versioning.md](versioning.md) demote guidance (~15 labelled issues).

## Rubric (agent must answer)

For the shipped surface, list anything that is **not** fully Working:

| Check | Absorb or Debt/Doc if… |
|-------|------------------------|
| **Data plane** | create/describe works but bytes/SQL/invoke/traffic don’t |
| **Authz** | only admin/root path tested; workload role deny missing |
| **Console** | list-only, Create disabled, “use CLI/smoke”, empty tabs, missing detail |
| **AWS console UI** | shipped service missing an AWS console surface. Title `Debt: <service> console (from #<n>)` only if Impact ≥ 3; else unlabelled backlog. Designs use Open Design `web-clone` (`./bin/od-design-run.sh`) |
| **Open Design first** | Console / web UI shipped without a `designing` phase — mocks under `design/` grey-rose theme dirs (historic names until [#421](https://github.com/kgz/stackwrangler/issues/421); web-clone when AWS has the screen). Fix before `done`; do not invent layout |
| **Dead controls** | Enabled button/link that no-ops or only toasts. Not wired → `disabled` + `title="To implement"` (+ Debt if Impact ≥ 3 for v1 surface). Never ship → omit |
| **Sidecar / bridge** | real AWS shape deferred to a compose hack |
| **Dual endpoints** | console vs CLI hit different backends |
| **Docs/README** | Partial/Sidecar status with **no** issue link |
| **Smokes** | happy path only; no deliberate failure case — update [smoke-matrix.md](smoke-matrix.md) |
| **Smoke matrix** | row missing or Sad column empty with no Debt link |
| **Path rubric** | scenario not listed in [test-paths.md](test-paths.md) |
| **Public docs** | New Working/Partial surface ships with no docs-site or [interactions](../docs-site/guide/interactions/) page, and this PR did not add one → `Doc:` |
| **Screenshot** | Console/UI change needs a product shot and [docs-capture](docs-catalog.md) was skipped → `Doc:` |
| **Interaction edge** | New cross-service path with no catalog entry under `docs-site/guide/interactions/` → `Doc:` (or add the page in this PR) |

Prefer shipping docs in the parent PR. File **Doc:** only when blocked. Same “no half-baked without follow-up” bar as Debt.

## Debt ticket shape

```text
Title: Debt: <short gap> (from #<parent>)
Body: Why / Goal / Acceptance / Related #<parent>
          Impact: N / Effort: N   (also set via ./bin/issue-score.sh)
Milestone: pillar for where the gap lives (see docs/version-plan.md)
Label: only if theme + Impact gate match an open cut — else no version label
Board: backlog — `./bin/issue-score.sh` sets Status=Backlog on first project add;
          still run `./bin/board-status.sh backlog <n>` if the card was added another way
Tracker: bin/board-tracker.tsv
Link from docs and/or README status row
```

Placement: [docs/versioning.md](versioning.md) — evaluate and place; do not displace other tickets.

## Doc: ticket shape

```text
Title: Doc: <short gap> (from #<parent>)
Body: Why / Goal / Acceptance / Related #<parent>
  - pages to add/update
  - edges to document
  - screenshots required
Milestone: pillar for the area
Label: only if cut gate matches — else no version label
Board: backlog
Tracker: bin/board-tracker.tsv
Link from catalog index or parent PR
```

Full template + capture commands: [docs-catalog.md](docs-catalog.md).

## Examples we already needed

- Transfer native SSH keys (was sidecar password) → [#141](https://github.com/kgz/stackwrangler/issues/141)
- Dual S3 → [#143](https://github.com/kgz/stackwrangler/issues/143)
- Workload IAM → [#144](https://github.com/kgz/stackwrangler/issues/144)
- RDS create/Aurora → [#145](https://github.com/kgz/stackwrangler/issues/145) (console Create shipped; Doc shot [#556](https://github.com/kgz/awsl/issues/556); Aurora failover [#225](https://github.com/kgz/awsl/issues/225))
- ECS/EC2 UI depth → [#146](https://github.com/kgz/stackwrangler/issues/146)
- Console Create/detail program → [#350](https://github.com/kgz/stackwrangler/issues/350) (Lambda [#351](https://github.com/kgz/stackwrangler/issues/351), Logs [#352](https://github.com/kgz/stackwrangler/issues/352), IAM users [#353](https://github.com/kgz/stackwrangler/issues/353), HTTP API detail [#354](https://github.com/kgz/stackwrangler/issues/354))
