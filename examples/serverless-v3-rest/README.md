# serverless-v3-rest (replication fixture)

Dummy Serverless Framework v3 REST API used to replay a real stack's AWS shape
on awsbox. Handlers are stubs; only the resources matter. Each ticket adds one
runnable slice under `slices/<name>/`.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| `slices/schedule/` | [#297](https://github.com/kgz/awsl/issues/297) | `./bin/events-schedule-smoke.sh` |

The parent fixture ([#185](https://github.com/kgz/awsl/issues/185)) is not
implemented yet; slices here are self-contained.
