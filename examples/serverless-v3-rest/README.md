# serverless-v3-rest (replication fixture)

Shared Serverless Framework v3 shape for high-focus tickets. Parent project: [#185](https://github.com/kgz/awsl/issues/185).

| Slice | Ticket | Smoke |
|-------|--------|-------|
| `slices/codedeploy/` | [#98](https://github.com/kgz/awsl/issues/98) | `./bin/codedeploy-smoke.sh` |

Other slices land with their tickets. Until #185 merges the base `serverless.yml`, each slice runs alone via its smoke.
