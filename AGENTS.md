# awsl / awsbox AI workflow

Same shape as Colony / Funds Manager. Board: [Project #8](https://github.com/users/kgz/projects/8/views/1).

## Ticket first

```bash
./bin/board-status.sh in-progress <issue-num>
```

Web UI / console tickets start in **designing**, then **in-progress** after Open Design mocks exist.

Closing: `./bin/board-status.sh done <n>`. Keep `bin/board-tracker.tsv` in sync, then `./bin/board-audit.sh --apply`.

Lifecycle: **Backlog** → **Ready** → **Designing** → **In progress** → **In review** → **Done**.

## Versioning (milestones + release label)

- **Milestone** = service catalogue (`v1 — Networking`, …). Keep these.
- **Label** = product release semver from [docs/CURRENT_RELEASE](docs/CURRENT_RELEASE) (started at **`v0.0.1`**; former “everything under v1 catalogues” maps here).
- New / Debt tickets: set milestone **and** `gh issue edit <n> --add-label "$(cat docs/CURRENT_RELEASE)"`.
- **In progress / in review** → always label `$(cat docs/CURRENT_RELEASE)` (drop other `v0.0.x`). Backlog planning may use `v0.0.2` / `v0.0.3`.
- Cut a release: `./bin/release-tag.sh v0.0.2` (git tag + GitHub Release + label + bump CURRENT_RELEASE). See [docs/versioning.md](docs/versioning.md).

## Branch

```bash
git checkout main && git pull origin main
git checkout -b feature/<issue>-<short-slug>
```

## Product north star

`docs/vision.md` — long-term feel (not a ticket).
OpenSpec changes are for **one delivery**; don’t park the whole product vision there.

## OpenSpec

- On `main`: `/opsx-propose` → `openspec/changes/<change-name>/`
- Delivery branch: `/opsx-apply` against `tasks.md`
- Grow `openspec/specs/` as shipped behaviour (archive changes separately)

## Open Design (required before web UI)

Any ticket that adds or changes **console / web UI** must go through Open Design **before** React implementation:

1. `./bin/board-status.sh designing <n>` (also set by `./bin/od-design-run.sh --issue <n>`)
2. Theme: `design/awsbox/` (grey rose)
3. `./bin/od-design-run.sh --issue <n> "…"` — prefer **web-clone** when the AWS console has that screen; read-only screenshots OK
4. Dead controls: not wired yet → `disabled` + `title="To implement"` (+ Debt if v1 needs it). Never ship it → omit from the mock. No enabled no-op / toast-only controls.
5. Land mocks in `design/awsbox-console/`
6. Then `./bin/board-status.sh in-progress <n>` and implement

Never raw `curl` for OD runs.

## Commits / PRs

- No `Co-authored-by` / agent attribution
- PR body: `Closes #<n>`

## Gap check before `done` (required)

**Before** `./bin/board-status.sh done <n>` / merge:

```bash
./bin/gap-check.sh <n>
```

1. Walk the checklist in `docs/gap-check.md`
2. For every Partial / disabled Create / sidecar / “use CLI smoke” / authz hole / AWS console UI left out of v1 **without** an open Debt ticket → create `Debt: … (from #<n>)`, `backlog`, label `$(cat docs/CURRENT_RELEASE)`, tracker row, link from README or service doc. Console debt designs use Open Design `web-clone`
3. Mention new Debt issues in the PR body

Do **not** mark the parent done until gaps are ticketed (or explicitly N/A in the PR).

---

# Real AWS cost — ask first

**Never** create, update, or leave running resources in a **real** AWS account without the user **explicitly approving that action in the current turn**.

## Allowed without asking

- **Local** awsbox / LocalEmu / SeaweedFS / Docker
- **Read-only** on real AWS when already authenticated (list/describe/screenshot) — no Create / Update / Delete / purchase
