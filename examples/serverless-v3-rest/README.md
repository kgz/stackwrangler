# serverless-v3-rest (fixture)

Dummy Serverless Framework v3 REST stack used to replicate a real-world AWS shape.
Handlers are stubs; only the AWS resources matter. Each ticket adds one slice under `slices/<name>/` that runs alone.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| [`slices/ddb`](slices/ddb) | [#296](https://github.com/kgz/awsl/issues/296) | `./bin/dynamodb-depth-smoke.sh` |

The full fixture is tracked in [#185](https://github.com/kgz/awsl/issues/185).
