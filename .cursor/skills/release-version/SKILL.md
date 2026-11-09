---
name: release-version
description: >-
  Product release labels, git tags, and the cut loop (ship cut → publish →
  re-evaluate next) for awsbox/stackwrangler. Use when creating tickets with a
  release label, cutting a semver release, tagging vX.Y.Z, updating
  CURRENT_RELEASE / versioning docs / docs-site changelog, or asking what to
  do after a cut ships.
---

# Release versioning

**Pillars** (milestones: `Platform`, `Identity & authz`, …) are categories.  
**Product cuts** are **labels + git tags** (`v0.0.2` Public, `v0.0.3` Trust, …).

Canonical docs: `docs/versioning.md`, `docs/version-plan.md`, `docs/CURRENT_RELEASE`, docs-site changelog `docs-site/guide/changelog.md`.

## Development loop (cut → publish → re-evaluate)

Do **not** pre-label three versions ahead and grind forever. One open cut at a time:

### 1. Execute the current cut

1. Work the Project #8 view for `$(cat docs/CURRENT_RELEASE)` (or the cut the user named).
2. Order: Impact ↓, Effort ↑ (`./bin/issue-score.sh` / board fields).
3. Ship → merge PR → `./bin/board-status.sh done <n>` → **delete the head branch** (remote + local) and remove the worktree if any. See [Branch & PR cleanup](#branch--pr-cleanup).
4. New gaps: absorb if small (`docs/gap-check.md`); else score + pillar; **release label only if this cut’s gate matches**. Never dump unrelated Debt onto the active cut.

### 2. Publish when the theme is done

Cut’s theme actually finished (or residuals explicitly waived). **Only when the user asks.**

#### Changelog (required before / with the tag)

Ship a docs-site entry for the cut — do not leave GitHub Release as the only notes.

1. Edit **`docs-site/guide/changelog.md`**: add `## vX.Y.Z — <Theme> (YYYY-MM-DD)` at the top (newest first). Include:
   - Short theme blurb
   - Grouped highlights (install/platform, identity, console, fidelity, …) with issue links
   - **Install this cut** — full GHCR `docker run … up` using **`:vX.Y.Z`** (not only `:latest`); note that one `up` starts APIs + profile `local` + **console web app** on `:3000`; optional digest pin + thin Release CLI asset
   - Link related examples (e.g. Terraform tour) when they exist
2. Keep nav/sidebar **Changelog** → `/guide/changelog` in `docs-site/.vitepress/config.mts` (already wired; restore if removed).
3. Link the cut from `docs-site/guide/completeness.md` / getting-started only if useful — do not duplicate the whole entry.
4. Land the changelog (and any install copy tweaks) on **`main` before or in the same ship window as the tag** so Pages deploys the notes with the release.

#### Tag + GitHub Release

```bash
./bin/release-tag.sh vX.Y.Z
```

That tags `origin/main` (or `--sha`), creates the GitHub Release, ensures the label exists, writes `docs/CURRENT_RELEASE`.

5. **Align Release body** with the docs changelog (same install one-liner + highlights). Prefer `gh api` PATCH of the release if `gh release edit` is unavailable.
6. Confirm GHCR publish + Release asset `install/stackwrangler` (re-upload / `workflow_dispatch` publish-images if the tag-push job skipped the CLI asset).
7. Commit the `CURRENT_RELEASE` bump to the **next** open cut (e.g. after `v0.0.2` → `v0.0.3`) and mark the shipped cut in `docs/version-plan.md`.

Do not cut **Public** while open Impact ≥ 5 core trust bugs are unwaived.

After publish, that cut’s board view should be empty (or only waived leftovers).

### 3. Re-evaluate the next cut(s)

1. Confirm the next theme still matches [version-plan.md](docs/version-plan.md) (Public → Trust → Accuracy → Security/deps → Maturity/testing → Org path).
2. From **No version** / **Unscored**, pull issues that now match that cut’s **theme + Impact gate**; add the next label + scores.
3. Leave everything else **unlabelled** (milestone only).
4. Ensure the board view for the new cut exists (filter `label:vX.Y.Z`, sort Impact ↓ Effort ↑). Create label + view together if opening a cut that was parked.
5. Set work focus to the new `CURRENT_RELEASE` view and return to step 1.

Soft WIP: if a cut grows past ~15 open labelled issues, deliberate demote pass — lowest Impact then highest Effort → next cut or unlabelled. Never auto-displace on Debt create.

## New tickets

```bash
# after gh issue create … — pillar milestone, then scores:
./bin/issue-score.sh <n> --impact=N --effort=N
# release label ONLY if theme + Impact gate match (docs/versioning.md):
# gh issue edit <n> --add-label v0.0.3
```

Do **not** default to `$(cat docs/CURRENT_RELEASE)`.

Debt: absorb small gaps in-parent (`docs/gap-check.md`); else evaluate-and-place with scores + pillar; label only if gate matches.

## Cuts (active)

| Label | Theme | Gate |
|-------|-------|------|
| `v0.0.2` | Public | `public-ready` / blocks public |
| `v0.0.3` | Trust | Impact ≥ 4 core bug/authz |
| `v0.0.4` | Accuracy | Impact ≥ 3 core debt/docs |
| `v0.0.5` | Security / deps | Dependabot / lockfile; Impact ≥ 3 product (≥ 2 examples) |
| `v0.0.6` | Maturity / testing | smoke/parity/proof Impact ≥ 3; CI/docs ≥ 2 |
| `v0.1.0` | Org path | path-critical |

Far-future labels (`v0.1.1`, `v0.1.2`, `v1.0.0`) stay parked until deliberately opened in step 3.

## Branch & PR cleanup

Stale `feature/*` / `batch/*` branches pile up fast. After every merge (or abandoned PR), clean up in the same turn:

```bash
# Prefer delete-branch on merge:
gh pr merge <pr> --merge --delete-branch
# If already merged without delete:
gh pr view <pr> --json headRefName -q .headRefName   # note BRANCH
git push origin --delete "$BRANCH"                    # remote
git branch -d "$BRANCH" 2>/dev/null || git branch -D "$BRANCH"
git worktree list
git worktree remove <path> 2>/dev/null || true        # if a wt used that branch
git fetch --prune
```

- Merged PR → delete remote head + local branch + worktree.
- Closed / abandoned PR (not merging) → same deletes once the user confirms abandon (or the ticket is dropped).
- After a `batch/…` lands on the default branch → delete the batch branch and each ticket branch that was only for that batch.
- Do not leave “merged but branch still on origin” — that is how we get ~100 dead branches.
- Periodic hygiene when asked: `git fetch --prune` then list `git branch -r` / `gh api repos/…/branches` for `feature/*` and `batch/*` with no open PR and already merged → delete.
