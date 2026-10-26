# PR review gate

PRs should not merge until an acceptance review is clean.

## Soft gate (this repo today)

Private repos on free GitHub **cannot** use classic branch protection / rulesets (“Upgrade to GitHub Pro or make this repository public”).

Until that changes, CI workflow `orchestrator-review` fails unless one of:

1. Label **`orchestrator-reviewed`** is on the PR (set by the ticket-batch orchestrator when acceptance review reports `must-fix: none`), or
2. An **APPROVED** review exists from someone **other than** the PR author (GitHub forbids self-approve).

The ticket-batch skill requires the orchestrator to apply that label (and try `gh pr review --approve` when a non-author token is available) before putting a ticket on the `batch/…` branch or asking to merge.

## Hard gate (when Pro or public)

In repo **Settings → Rules → Rulesets** (or Branches), protect `main` and `beta/full-flow-v1`:

- Require a pull request before merging
- Required approvals: 1
- Dismiss stale approvals when new commits are pushed
- Require status checks to pass: **`orchestrator-review` / `reviewed`**
- Do not allow bypassing the above for admins (optional but preferred)

Then the label/approval check is enforced by GitHub as well as by the agent workflow.
