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
| **AWS console UI** | v1 of a service ships without a console surface AWS has for it. Title `Debt: <service> console (from #<n>)`. Designs use Open Design `web-clone` (`./bin/od-design-run.sh`), not a guessed layout |
| **Open Design first** | Console / web UI shipped without a `designing` phase — mocks in `design/awsbox-console/` using `design/awsbox/` theme (web-clone when AWS has the screen). Fix before `done`; do not invent layout |
| **Dead controls** | Enabled button/link that no-ops or only toasts. Not wired → `disabled` + `title="To implement"` (+ Debt if v1). Never ship → omit from mock and product UI |
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
Label: $(cat docs/CURRENT_RELEASE)   # product cut; see docs/versioning.md
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
- Console Create/detail program → [#350](https://github.com/kgz/awsl/issues/350) (Lambda [#351](https://github.com/kgz/awsl/issues/351), Logs [#352](https://github.com/kgz/awsl/issues/352), IAM users [#353](https://github.com/kgz/awsl/issues/353), HTTP API detail [#354](https://github.com/kgz/awsl/issues/354))
