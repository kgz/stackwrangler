---
name: ticket-batch
description: >-
  Orchestrate a batch of GitHub tickets with cheaper subagents, one worktree
  and PR per ticket, an acceptance-criteria review, and a batch branch for
  joint testing. Use when the user asks to bulk-process development, work
  through several tickets, run a ticket batch, or orchestrate agents across
  a set of issues.
---

# Ticket batch

You are the orchestrator. You do not implement tickets in this session. Workers edit code. A different agent reviews.

Invoking this skill approves, for the tickets named in this turn: branch, commit, push, open a PR per ticket, and push a `batch/` branch. It does not approve merging to the default branch, marking tickets done, or creating resources in a real AWS account.

## Stop line

Each ticket ends as an open PR. Passing tickets merge into `batch/<date-or-name>` so they can be tested together. Conflicts are reported and left unresolved. Nothing merges to the default branch until the user says so in a later turn.

## 1. Scope

Take only what this turn names: issue numbers, an epic's sub-issues, or one board column (`backlog`, `designing`, `in-progress`). Do not pull a whole board.

If an issue is assigned to someone other than `gh api user -q .login`, skip it and say so.

Read the repo workflow before spawning anyone: `AGENTS.md`, `.cursor/rules/`, and the header of any `bin/board-status.sh` and `docs/gap-check.md`. Obey that flow. Do not invent statuses or scripts the repo does not have.

## 2. Models

**Always `model: "inherit"`** for implement and review workers (and any other Task launch from this skill). Do not pick Claude / Grok / Gemini / GPT / Muse / “Other Models” slugs — the user routes via Auto / Cursor default only.

Scout remains `explore` with no model argument.

One acceptance reviewer per PR. Do not launch Bugbot.

## 3. Isolate

Default is local git worktrees. Use a cloud subagent only when the user says cloud (`environment: "cloud"`, `cloud_base_branch` = the default branch). Do not set cloud otherwise.

Local setup, from the repo root:

```bash
git fetch origin
BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')
DATE=$(date +%F)
git worktree add -b "feature/<issue>-<slug>" "../<repo>-wt-<issue>" "origin/$BASE"
```

`<repo>` is the directory name. Slug is a few words from the issue title. If the branch or worktree already exists, stop that ticket and report it.

Cap parallel workers at 3. Tickets that will edit the same files run one after another. Shared local services (one Docker Compose project, fixed ports such as `:4566`) run one at a time even when implementation was parallel.

Launch workers with the Task tool: `subagent_type: "generalPurpose"`, `run_in_background: true`, the tier's model, and the worker prompt below. Do not invent Task parameters. After the wave is launched, end the turn. Continue when a worker finishes. Do not poll.

## 4. Worker prompt

Fill this in. The worker does not see this skill.

```
Work only in <absolute worktree path>. Every shell command uses that working directory. Every file path is absolute under that worktree. Do not touch the parent checkout.

Issue: #<n>
<title and body, verbatim>

Repo rules to follow (from AGENTS.md and the board docs):
- Branch is feature/<issue>-<slug> (already exists if continuing). Base is origin/<base> — rebase onto it before finishing if the branch is behind.
- If an open PR already exists for this branch, update that PR; do not open a duplicate.
- Web UI / console tickets: Open Design first. Set board to `designing`, run `./bin/od-design-run.sh --issue <n> "…"`, use theme grey-rose under `design/` (historic dir names — #421), prefer skill `web-clone` when the screen exists in real AWS (read-only screenshots OK). Land mocks under the console design folder before React. Unwired controls: `disabled` + `title="To implement"` (+ Debt only if cut gate matches; see anti-debt-loop). Never-ship controls: omit. No enabled no-ops. Only then `export STACKWRANGLER_AGENT=cursor-batch-<slug>; ./bin/board-status.sh in-progress <n>` (Project field Agent — no per-agent labels; AWSBOX_AGENT still works as fallback). Non-UI tickets start at in-progress the same way.
- Move the board to in-progress before code edits (after designing when UI), and to in-review when the PR is open/updated, using only the repo's script. If bin/board-tracker.tsv has a row for this issue, set that row's expected status to match. Do not run board-audit --apply.
- Do not mark the ticket done.
- Run the tests the ticket and the repo docs require. If a gap-check script exists, run ./bin/gap-check.sh <n>. Prefer absorbing small additive gaps into this PR; otherwise file scored Debt (pillar + Impact/Effort; release label only if cut gate matches — never auto CURRENT_RELEASE).
- Commit with a short message about why. No Co-authored-by or agent attribution.
- Push and open a PR against <base>. Body includes Closes #<n> and the test plan. Do not merge.

No writes to a real AWS account. Local emulators only.

Return: branch, PR URL, commands you ran and their results, files touched, gap-check result, anything you did not finish.
```

## 5. Review

After a worker's PR exists, launch one fresh `generalPurpose` agent to review it. It reads the acceptance criteria and also reviews security, correctness, quality, tests, duplicate code, and reuse. Use the review-tier model. Read [review-prompt.md](review-prompt.md) and pass that prompt. Background is fine.

The prompt contains the PR number and the issue number only. The reviewer loads the issue with `gh issue view` itself. Do not include the worker's prompt, its summary, or why it built the change that way.

Findings are `must-fix`, `potential-follow-up`, or `note`. Must-fix means a missed acceptance line, a bug, a security issue, a missing test for this ticket, or duplicate code where a helper already exists. Something real that the acceptance criteria do not require, including future reuse, is a `potential-follow-up`, and only when no open or closed issue already covers it. The reviewer cites the existing issue when one does.

Record every step on the PR with `gh pr comment`. Post the worker's test and gap-check result once the PR exists. Post each review verbatim, labeled `Review — round N/3`, including the implement and review model slugs. Do not paraphrase the review away.

Must-fix goes back to the same worker (`resume` that agent), then a new reviewer runs. Cap three review rounds per ticket. If round 3 still has must-fix items, stop that ticket, leave it off the batch branch, and post this comment:

```
## Review failed 3 times

Left off `batch/<name>`.
Open must-fix items from round 3:

<verbatim must-fix list>
```

You decide each `potential-follow-up`. Prefer absorb-in-parent when Effort ≤ 2 and same service. File Debt only when the gap is real, uncovered, and too big to absorb — with pillar + `./bin/issue-score.sh` and a release label only if the cut gate matches (`docs/versioning.md`). Never auto-label `$(cat docs/CURRENT_RELEASE)`. Skip when already filed, out of scope, or not worth tracking. Comment: filed as `#N`, absorbed, or skipped. Potential follow-ups do not fail the review and do not block the batch.

**Anti-debt-loop (required):** Console / create-detail MVP tickets almost always leave AWS chrome as `disabled` + `title="To implement"` (delete, receive, put-targets, tags, Actions, …). Do **not** promote every leftover stub into the open cut. Default those children to **unlabelled backlog** (score Impact/Effort; often Impact ≤ 2). Put a release label on follow-up Debt only when the gap is behaviour mismatch, false-confidence authz, missing smoke for shipped behaviour, or otherwise meets the cut’s Impact gate for a real accuracy/trust problem — not “more console chrome after MVP.” Filing the ticket is fine; stuffing it into `CURRENT_RELEASE` is what creates a perpetual Debt loop. If the open cut already has ~15+ labelled issues, prefer unlabelled unless the gap is clearly cut-critical.

v1 that leaves out an AWS console UI for that service is Debt. Do not skip it as not worth tracking. Title `Debt: <service> console (from #<n>)`. Score + pillar; release label only if Impact ≥ 3 and the cut theme matches — else unlabelled backlog. If `./bin/od-design-run.sh` exists, the debt's designs go through Open Design `web-clone`, not a guessed layout.

Web UI PRs that skipped Open Design / `designing` (no grey-rose mocks under `design/`) are must-fix — send back to designing, do not batch.

Move the board to in-review when the PR is open. Leave it there.

## 6. Batch branch

When the wave's reviews are in:

```bash
git fetch origin
DATE=$(date +%F)
git branch "batch/$DATE" "origin/$BASE"   # or batch/<name> if the user gave one
```

Merge each surviving ticket branch in with `git merge --no-ff`. On conflict, `git merge --abort`, leave that ticket off the branch, and comment the conflicting files on its PR. Do not resolve conflicts in this skill. Push `batch/…` and do not open a PR from it. When a ticket lands on the batch branch, comment that branch name on its PR.

## 7. Report

```
| Issue | Tier | PR | Review | On batch branch |
| #n | implement | url | clean / failed 3 times (logged on PR) | yes / conflict logged on PR |
```

Then the batch branch name, tickets skipped, and potential follow-ups you filed or skipped. The default branch was not merged.

## 8. Merge + branch cleanup (only when the user asks to merge)

When the user asks to merge ticket PRs and/or the batch into the default branch:

1. Merge with branch delete: `gh pr merge <pr> --merge --delete-branch` (or equivalent after squash/merge).
2. If the remote head remains: `git push origin --delete <branch>`.
3. Delete local branch + remove any `../<repo>-wt-<issue>` worktree for that branch.
4. After the batch is on default: delete remote/local `batch/<name>` and every ticket `feature/<n>-*` that has no open PR and is fully merged.
5. `git fetch --prune`. Report what was deleted.

Abandoned tickets (failed review / user drops): close the PR (`gh pr close <pr> --delete-branch` when supported, else close + `git push origin --delete`), remove the worktree, delete the local branch. Do not leave closed-PR heads on origin.

Do **not** accumulate merged feature/batch branches across batches — that is how we get ~100 dead remotes.
