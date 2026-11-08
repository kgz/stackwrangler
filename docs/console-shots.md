# Console docs screenshots

Produced by `./bin/docs-capture.sh` (Playwright project `docs-capture`).  
PNG paths are under `docs/assets/console/` (docs-site serves them via `public/assets` symlink). Keep this registry **outside** `public/` so VitePress does not treat it as a page.

| File | Console URL | Seed / note |
|------|-------------|-------------|
| `home-s3-buckets.png` | `/` | Optional: `aws --profile local s3 mb s3://docs-demo-bucket` |
| `empty-specialty-buckets.png` | `/directory-buckets` | Empty chrome is honest |
| `lambda-functions.png` | `/lambda` | Optional: seed a tiny function for non-empty list |
| `cloudformation-stacks.png` | `/cloudformation` | List page; empty OK if honest |
| `cloudformation-stacksets.png` | `/cloudformation/stacksets` | StackSets list; empty OK + honesty [#95](https://github.com/kgz/awsl/issues/95) |
| `ecs-clusters.png` | `/ecs` | List page · create at `/ecs/create`; cluster/task detail under `/ecs/clusters/…` |
| `ec2-instances.png` | `/ec2` | List page · instance detail at `/ec2/instances/:id` |
| `sfn-state-machines.png` | `/stepfunctions` | Optional: seed via `sfn-smoke.sh` / e2e create; empty OK |
| `secrets-list.png` | `/secretsmanager` | Optional: seed via `secrets-smoke.sh` / e2e create; empty OK |
| `kms-keys.png` | `/kms` | Optional: seed via `kms-smoke.sh` / e2e create; empty OK |
| `eventbridge-rules.png` | `/events` | Optional: seed via `events-smoke.sh` / e2e create; empty OK |
| `rds-databases.png` | `/rds` | Optional: seed via `rds-smoke.sh` / Create database e2e; empty OK |
| `apigateway-rest-apis.png` | `/apigateway/rest-apis` | Optional: seed via `apigw-rest-smoke.sh`; empty OK |
| `sns-topics.png` | `/sns` | Optional: seed via `sns-sqs-fanout-smoke.sh`; empty OK |
| `sqs-queues.png` | `/sqs` | Optional: seed via `sns-sqs-fanout-smoke.sh`; empty OK |
| `kinesis-streams.png` | `/kinesis` | Optional: seed via `kinesis-smoke.sh` / e2e create; empty OK · create/detail [#539](https://github.com/kgz/awsl/issues/539) |

No seed for a new shot → file **Doc:**; do not invent images or use `design/**/refs/` AWS recon PNGs.
