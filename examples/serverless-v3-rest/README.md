# serverless-v3-rest (replication fixture)

Dummy Serverless Framework v3 REST stack used to replicate a real serverless layout. Only the AWS shape matters; handlers are stubs. The full project is [#185](https://github.com/kgz/awsl/issues/185). Each slice is standalone under `slices/<name>/`, so a ticket's smoke runs without the rest.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| [api-keys](slices/api-keys/) | [#294](https://github.com/kgz/awsl/issues/294) | `./bin/apigw-usage-plan-smoke.sh` |
| [transfer-out](slices/transfer-out/) | [#295](https://github.com/kgz/awsl/issues/295) | `./bin/transfer-connector-smoke.sh` |
| [ddb](slices/ddb/) | [#296](https://github.com/kgz/awsl/issues/296) | `./bin/dynamodb-depth-smoke.sh` |
| [schedule](slices/schedule/) | [#297](https://github.com/kgz/awsl/issues/297) | `./bin/events-schedule-smoke.sh` |
| [apigw-authz](slices/apigw-authz/) | [#190](https://github.com/kgz/awsl/issues/190) | `./bin/apigw-rest-smoke.sh` |
| [transfer-in](slices/transfer-in/) | [#141](https://github.com/kgz/awsl/issues/141) | `./bin/transfer-key-smoke.sh` |
| [waf](slices/waf/) | [#55](https://github.com/kgz/awsl/issues/55) | `./bin/waf-smoke.sh` |
