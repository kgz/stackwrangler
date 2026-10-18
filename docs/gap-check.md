# Post-ticket gap check (cheap)

Run **before** marking a ticket `done` / merging the PR. Goal: no half-baked CLI/UI ships without a **Debt:** follow-up on the board.

```bash
./bin/gap-check.sh <issue-num>   # prints checklist + heuristic hits
```

## Rubric (agent must answer)

For the shipped surface, list anything that is **not** fully Working:

| Check | File Debt ticket if… |
|-------|----------------------|
| **Data plane** | create/describe works but bytes/SQL/invoke/traffic don’t |
| **Authz** | only admin/root path tested; workload role deny missing |
| **Console** | list-only, Create disabled, “use CLI/smoke”, empty tabs, missing detail |
| **Sidecar / bridge** | real AWS shape deferred to a compose hack |
| **Dual endpoints** | console vs CLI hit different backends |
| **Docs/README** | Partial/Sidecar status with **no** issue link |
| **Smokes** | happy path only; no deliberate failure case — update [smoke-matrix.md](smoke-matrix.md) |
| **Smoke matrix** | row missing or Sad column empty with no Debt link |
| **Path rubric** | scenario not listed in [test-paths.md](test-paths.md) |

## Debt ticket shape

```text
Title: Debt: <short gap> (from #<parent>)
Body: Why / Goal / Acceptance / Related #<parent>
Milestone: same area as parent
Board: backlog
Tracker: bin/board-tracker.tsv
Link from docs and/or README status row
```

## Examples we already needed

- Transfer sidecar password → [#141](https://github.com/kgz/awsl/issues/141)
- Dual S3 → [#143](https://github.com/kgz/awsl/issues/143)
- Workload IAM → [#144](https://github.com/kgz/awsl/issues/144)
- RDS create/Aurora → [#145](https://github.com/kgz/awsl/issues/145)
- ECS/EC2 UI depth → [#146](https://github.com/kgz/awsl/issues/146)
