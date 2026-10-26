# serverless-v3-rest (replication fixture)

Dummy Serverless Framework v3 REST stack used to replicate a real serverless layout. Only the AWS shape matters; handlers are stubs. The full project is [#185](https://github.com/kgz/awsl/issues/185). Each slice is standalone under `slices/<name>/`, so a ticket's smoke runs without the rest.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| [egress](slices/egress/) | [#230](https://github.com/kgz/awsl/issues/230) | `./bin/vpc-egress-smoke.sh` |
