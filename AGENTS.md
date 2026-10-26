# awsl / awsbox AI workflow

Same shape as Colony / Funds Manager. Board: [Project #8](https://github.com/users/kgz/projects/8/views/1).

## Ticket first

```bash
./bin/board-status.sh in-progress <issue-num>
```

Closing: `./bin/board-status.sh done <n>`. Keep `bin/board-tracker.tsv` in sync, then `./bin/board-audit.sh --apply`.

Lifecycle: **Backlog** → **Ready** → **In progress** → **Done**.

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

## Open Design

Never raw `curl` for runs. Use:

```bash
./bin/od-design-run.sh --issue <n> "Design prompt…"
```

Console mocks live in `design/awsbox-console/` (OD `baseDir`).

## Commits / PRs

- No `Co-authored-by` / agent attribution
- PR body: `Closes #<n>`

## Gap check before `done` (required)

User relies on the agent to not lose half-baked follow-ups (especially UI stubs).

**Before** `./bin/board-status.sh done <n>` / merge:

```bash
./bin/gap-check.sh <n>
```

1. Walk the checklist in `docs/gap-check.md`
2. For every Partial / disabled Create / sidecar / “use CLI smoke” / authz hole **without** an open Debt ticket → create `Debt: … (from #<n>)`, `backlog`, tracker row, link from README or service doc
3. Mention new Debt issues in the PR body

Do **not** mark the parent done until gaps are ticketed (or explicitly N/A in the PR).

---

# Real AWS cost — ask first

**Never** create, update, or leave running resources in a **real** AWS account (CLI, console automation, SDK, CloudFormation, etc.) without the user **explicitly approving that action in the current turn**.

This includes “cheap” or free-tier-ish things (SSM Parameter, empty S3 bucket, tiny SNS topic, CFN stack with only metadata). **$0–$1 × many still counts** — do not batch unapproved creates.

## Allowed without asking

- **Local** awsbox / LocalEmu / SeaweedFS / Docker (`--profile local`, `:4566`, `:8333`)
- **Read-only** on real AWS when already authenticated for viewing UI (list/describe/screenshot) — no Create / Update / Delete / purchase

## Before any real-AWS write

1. State exactly what will be created (resource types + region)
2. Estimate cost — **including residuals after teardown** (min deletion windows, retention locks, idle provisioned capacity)
3. Say how it will be deleted afterward
4. **Wait for explicit yes** (“go ahead”, “approved”, etc.)

**Residuals count.** “Delete after 5 minutes” is not enough if AWS forces a cooldown (e.g. KMS CMK **7-day** pending deletion ≈ cents–dollars until gone). State worst-case leftover bill duration + $ **before** asking for yes. Prefer designs that avoid sticky costs when a free/ephemeral alternative works.

If unsure whether an account is real vs local — treat as real and ask.
