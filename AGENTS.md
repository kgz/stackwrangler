# stackwrangler — agent / contributor guidance

Public defaults for agents and contributors. Private maintainer board tooling is **not** required to open a normal PR.

## Local stack

```bash
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
aws --profile local …
```

CLI entry is `./bin/stackwrangler` (`./bin/awsbox` is a one-line shim). Prefer `STACKWRANGLER_*` env vars where documented; some older `AWSBOX_*` names remain as fallbacks.

Smokes: [docs/test-paths.md](docs/test-paths.md) · [docs/smoke-matrix.md](docs/smoke-matrix.md) · [docs/smokes.md](docs/smokes.md).

## Branch / PR

```bash
git checkout main && git pull origin main
git checkout -b feature/<issue>-<short-slug>   # or feature/<short-slug>
```

- Focused change; match existing style
- Run the smokes that cover your area
- PR body: `Closes #<n>` when applicable
- No `Co-authored-by` / agent attribution
- No secrets or real AWS credentials in commits
- After merge (or abandon): delete the head branch on origin + locally, remove the worktree, `git fetch --prune`. Prefer `gh pr merge … --delete-branch`. Do not leave merged `feature/*` / `batch/*` branches on the remote.

## Versioning (pillars + release label + scores)

- **Milestone** = pillar (`Platform`, `Identity & authz`, …) — see [docs/version-plan.md](docs/version-plan.md).
- **Label** = product cut (`v0.0.2` Public, `v0.0.3` Trust, `v0.0.4` Accuracy, `v0.1.0` Org path). Only if theme + Impact gate match — otherwise **no version label**.
- New tickets: pillar + `./bin/issue-score.sh <n> --impact=N --effort=N`. Do **not** auto-label `CURRENT_RELEASE`. Freeze: every new issue needs pillar + scores; version label only if cut gate matches.
- Debt: absorb small gaps in-parent ([docs/gap-check.md](docs/gap-check.md)); else evaluate-and-place.
- Cut a release: `./bin/release-tag.sh vX.Y.Z` — only when asked. See [docs/versioning.md](docs/versioning.md).

## Product north star

`docs/vision.md` — long-term feel (not a ticket).
OpenSpec changes are for **one delivery**; don’t park the whole product vision there.

## Public README

Root `README.md` is product-facing. Keep Board/workflow, Project #8, `/opsx-*`, OD run scripts, and Agent-field docs **here** (and [CONTRIBUTING.md](CONTRIBUTING.md) → this file) — not on the landing page. Product rewrite is #402; status matrix may move to the docs site (#403).

## OpenSpec

- On `main`: `/opsx-propose` → `openspec/changes/<change-name>/`
- Delivery branch: `/opsx-apply` against `tasks.md`
- Grow `openspec/specs/` as shipped behaviour (archive changes separately)

## Open Design (required before web UI)

Any ticket that adds or changes **console / web UI** (`console/`, new service pages, chrome) must go through Open Design **before** React implementation:

1. Theme: grey rose under `design/` (historic directory names — [#421](https://github.com/kgz/stackwrangler/issues/421)). Do not invent a new palette or copy AWS orange / sky blue / smile.
2. Mocks: `./bin/od-design-run.sh --issue <n> "…"`. Prefer skill **web-clone** when the screen exists in real AWS. Read-only AWS console screenshots are allowed; never create/update/delete real resources without explicit approval.
3. **Dead controls:** not wired yet → `disabled` + `title="To implement"` (+ Debt if v1 needs it). Never ship it → omit from the mock. No enabled no-op / toast-only controls.
4. Land mocks under the console design folder in `design/` (or the ticket’s ticket design folder; [#421](https://github.com/kgz/stackwrangler/issues/421)).
5. Then implement against the mocks.

Never raw `curl` for OD runs — always `./bin/od-design-run.sh`.

## Gap check before merge

```bash
./bin/gap-check.sh <n>
```

1. Walk the checklist in `docs/gap-check.md`
2. Prefer **absorbing** small additive gaps into this PR. Otherwise file `Debt: … (from #<n>)` with pillar + Impact/Effort; release label only if cut gate matches (never default `CURRENT_RELEASE`). Tracker row + docs link. Console debt designs use Open Design `web-clone`
3. Prefer shipping docs in the PR; if blocked on public docs / screenshot / interaction edge → `Doc: … (from #<n>)` per [docs/docs-catalog.md](docs/docs-catalog.md) (skill `docs-catalog`). User-facing host/ports/Docker copy is **Linux-first** (not WSL-led; #491).
4. Mention new Debt / Doc issues (or “absorbed”) in the PR body

Do **not** treat the parent as finished until gaps are absorbed, ticketed, or explicitly N/A in the PR.

## Verify as the live principal

When you use stackwrangler to check a stack, a policy or a workload, **act as the principal that runs it live**: the CI deploy role for deploys, the task or execution role for workloads. Admin keys skip IAM, so a check run with them can't fail on permissions and proves nothing about them. If an emulator gap forces you to loosen a statement, loosen only that one and say so. See [docs/serverless-stackwrangler.md](docs/serverless-stackwrangler.md#deploy-as-the-deploy-role-admin-keys-skip-iam).

## Maintainers

Maintainers with GitHub **project** access may use `bin/board-status.sh` / `bin/board-tracker.tsv` / `bin/issue-score.sh`. Board lifecycle: **Backlog** → **Designing** → **In progress** → **In review** → **Done** (`ready` aliases to backlog). That loop is optional for external contributors (private board; clone ≠ project access).

---

# Real AWS cost — ask first

**Never** create, update, or leave running resources in a **real** AWS account without the user **explicitly approving that action in the current turn**.

## Allowed without asking

- **Local** stackwrangler / LocalEmu / SeaweedFS / Docker
- **Read-only** on real AWS when already authenticated (list/describe/screenshot) — no Create / Update / Delete / purchase
