# serverless-v3-rest (replication fixture)

Dummy Serverless Framework v3 project that mimics a real serverless stack for awsbox
replication tests. Handlers are stubs; only the AWS shape matters.

The full fixture is tracked in [#185](https://github.com/kgz/awsl/issues/185). Until it lands,
this directory holds only the slices that ship with their own tickets. Each slice lives in
`slices/<name>/` and runs alone through its smoke script.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| `slices/transfer-out/` | [#295](https://github.com/kgz/awsl/issues/295) | `./bin/transfer-connector-smoke.sh` |
