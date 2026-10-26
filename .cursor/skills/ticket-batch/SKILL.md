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

Real-AWS parity is **not** part of the implement/review wave. It runs only in a later turn after the user is happy with the batch **and** explicitly approves the cost (see §8).

## 1. Scope

Take only what this turn names: issue numbers, an epic's sub-issues, or one board column (`ready`, `in-progress`). Do not pull a whole board.

If an issue is assigned to someone other than `gh api user -q .login`, skip it and say so.

Read the repo workflow before spawning anyone: `AGENTS.md`, `.cursor/rules/`, and the header of any `bin/board-status.sh` and `docs/gap-check.md`. Obey that flow. Do not invent statuses or scripts the repo does not have.

## 2. Models

Pass `model` only from the session's available subagent model list. Never invent a slug. If a call rejects the slug, pick the next slug in the same tier. Do not retry the same slug.

| Tier | When | Pick |
|---|---|---|
| scout | Read the issue and find files | `explore`. No model argument. |
| implement | Clear ticket, local change | First slug containing `fast` or `medium`. Else a `sonnet`, `grok`, `gemini`, or `gpt` slug that does not contain `thinking` or `fable`. |
| implement-hard | Auth, data loss, payments, unclear acceptance criteria, or more than one service | First slug containing `high` that does not contain `thinking`. A `thinking` slug only after that worker has already failed once. |
| review | The acceptance reviewer | A slug that is not the implementer's. Prefer `sonnet`, `gpt`, or `opus` plus `medium` or `high`, with no `fast` and no `thinking`. |

`inherit` only when the list has no other usable slug. One acceptance reviewer per PR. Do not launch Bugbot.

## 3. Isolate

Default is local git worktrees. Use a cloud subagent only when the user says cloud (`environment: "cloud"`, `cloud_base_branch` = the default branch). Do not set cloud otherwise.

Local setup, from the repo root:

```bash
git fetch origin
BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')
# Override BASE when the user names a branch, or when open PRs for these
# tickets already share one base (e.g. beta/full-flow-v1).
DATE=$(date +%F)
```

`<repo>` is the directory name. Slug is a few words from the issue title.

### New vs already-started

| State | Action |
|---|---|
| No branch / no worktree | `git worktree add -b "feature/<issue>-<slug>" "../<repo>-wt-<issue>" "origin/$BASE"` |
| Branch and/or worktree already exists (open PR common) | **Continue** — do not stop the ticket. Reuse the worktree (or `git worktree add` checking out the existing branch). Worker rebases onto `origin/$BASE`, finishes acceptance, pushes the same PR (or opens one if missing). |
| Worktree path busy on a different branch | Stop that ticket and report it. |

Cap parallel workers at 3. Tickets that will edit the same files run one after another. Shared local services (one Docker Compose project, fixed ports such as `:4566`) run one at a time even when implementation was parallel. Honour hard dependencies (e.g. B needs A's merge) by ordering waves.

### Local smoke speed

Workers burn most of their time on **LocalEmu recreate + wait-healthy**, not on the assertion script. Require this discipline in the worker prompt (and enforce in review if they recreate unnecessarily):

1. **One warm stack per ticket.** `./bin/awsbox up` (or compose up) once. Do **not** `--force-recreate` / wipe volumes between edit iterations unless `localemu-patches/`, `docker-compose.yml`, or an `init/`/`start.d` hook changed.
2. **Background the long smoke.** After the stack is healthy, start the ticket smoke as a background job logging to `/tmp/<issue>-smoke.log` (e.g. `nohup ./bin/elbv2-smoke.sh > /tmp/203-smoke.log 2>&1 & echo $!`). While it runs, finish docs, tracker, gap-check draft, PR body. Then `wait` / tail the log and fix only if it failed. Do not sit in a foreground poll loop doing nothing else.
3. **Keep resources while iterating.** Prefer script `KEEP` / `AWSBOX_*_KEEP=1` (or the ticket's equivalent) so teardown is not paid on every failed attempt; full teardown once on the final green run (or leave KEEP and note it in the PR).
4. **Per-worktree ports when parallel.** If two LocalEmu stacks must run, set distinct `COMPOSE_PROJECT_NAME` and publish ports (e.g. `4566` vs `14566`) via compose override — never fight over one `:4566`. Still serialise when the ticket needs the canonical `:4566` smoke.
5. **One full smoke at the end.** After rebase/conflict resolution, make code changes, then **one** full smoke — not recreate→smoke→bisect unrelated beta patches unless that patch is required for this ticket's AC. Out-of-scope beta breakage → note on the PR / Debt, do not boil the ocean.

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
- Move the board to in-progress before editing, and to in-review when the PR is open/updated, using only the repo's script (if bin/board-status.sh exists: ./bin/board-status.sh in-progress <n>, then in-review). If bin/board-tracker.tsv has a row for this issue, set that row's expected status to match. Do not run board-audit --apply.
- Do not mark the ticket done.
- Run the tests the ticket and the repo docs require. Warm LocalEmu once; do not force-recreate between edits unless patches/compose/hooks changed. Start the long smoke in the background (log under /tmp/<n>-smoke.log), do docs/gap-check/PR text in parallel, then wait on the log. Use KEEP=1 while iterating; full teardown on final green (or note KEEP left on in the PR). One full smoke at the end — do not bisect unrelated beta failures unless they block this ticket's AC.
- If a gap-check script exists, run ./bin/gap-check.sh <n> and file any Debt ticket it requires before the PR (skip filing when an open Debt already covers the gap).
- Commit with a short message about why. No Co-authored-by or agent attribution.
- Push and open/update a PR against <base>. Body includes Closes #<n> and the test plan. Do not merge.

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

You decide each `potential-follow-up`. File a backlog ticket only when the gap is real and uncovered (this repo: `Debt: … (from #<n>)` when it matches gap-check). Skip it when it is already filed, out of scope, or not worth tracking. Comment the decision on the PR: filed as `#N`, or skipped, with the reason. Potential follow-ups do not fail the review and do not block the batch.

Move the board to in-review when the PR is open. Leave it there.

### Orchestrator marks reviewed (required before batch / merge)

When the latest review round has **`must-fix: none`** and you have triaged potential follow-ups, the orchestrator **must** mark the PR reviewed before putting it on the batch branch or telling the user it is merge-ready:

```bash
# Prefer a real APPROVED review when the token is not the PR author (GitHub blocks self-approve):
gh pr review <pr> --repo <owner>/<repo> --approve --body "Orchestrator: acceptance review clean (must-fix: none)."

# Always apply the CI gate label (works when the orchestrator is also the author):
gh api -X POST "repos/<owner>/<repo>/issues/<pr>/labels" -f "labels[]=orchestrator-reviewed"

gh pr comment <pr> --repo <owner>/<repo> --body "## Orchestrator — reviewed
Acceptance review clean (\`must-fix: none\`). Label \`orchestrator-reviewed\` applied. Eligible for \`batch/…\` / merge when the user asks."
```

If a later must-fix round re-opens, **remove** the label (`gh api -X DELETE repos/.../issues/<pr>/labels/orchestrator-reviewed`) and do not treat the PR as merge-ready until a clean round again.

Do **not** merge the default branch from this skill. See `docs/pr-review-gate.md`.

## 6. Batch branch

When the wave's reviews are in (only tickets with `orchestrator-reviewed`):

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

Then the batch branch name, tickets skipped, and potential follow-ups you filed or skipped. The default branch was not merged. Real-AWS parity was not run (needs a later explicit approval — §8).

## 8. Real-AWS parity (later turn only)

After the user says they are happy with the batch (or named tickets) **and** explicitly approves real-AWS spend in that turn:

1. Obey the repo's real-AWS cost rule (`.cursor/rules/aws-cost-approval.mdc` / `AGENTS.md`): list resource types + region, estimate cost **including residuals after teardown** (min deletion windows, retention locks, idle provisioned capacity — e.g. KMS CMK 7-day pending delete), say how teardown works, then wait for yes if not already given for this exact plan.
2. Prefer existing parity scripts in the repo (`bin/aws-parity-*.sh`, docs under `docs/aws-parity*.md`). Do not invent long-lived resources.
3. Run local-emulator checks first when the script supports skip flags; then real.
4. After the run: verify teardown (list leftover `awsbox-parity-*` / ticket-tagged resources). Report anything still billing and its end date (e.g. KMS `PendingDeletion`).
5. Only then, if the user asks, merge / board-done — parity success alone does not merge the default branch.

Invoking `/ticket-batch` for implement/review does **not** approve §8. A separate clear approval is required ("go ahead on real AWS parity", etc.).
