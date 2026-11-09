# Where local smokes live

New smokes go under `smokes/<area>/`. `bin/` stays product and tooling (`awsbox`, `e2e.sh`, board scripts).

Run a smoke by path:

```bash
./smokes/<area>/<name>.sh
```

`./bin/e2e.sh` invokes the same set via `./smokes/<area>/…` directly.

Inside a smoke, the repo root is two levels up:

```bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
```

To resolve a basename to its path (used by parity drivers):

```bash
source "$ROOT/smokes/lib/smoke-path.sh"
smoke_path lambda-smoke   # → $ROOT/smokes/lambda/lambda-smoke.sh
```

## Areas

Same spirit as the catalogue milestones. Match the script prefix, then the exceptions below.

| Dir | Put here |
|-----|----------|
| `smokes/lambda/` | `lambda-*` (incl. `lambda-ecr-smoke.sh`), `sqs-lambda-dlq-smoke.sh`, `sqs-lambda-batch-failures-smoke.sh`, `sqs-lambda-esm-enable-smoke.sh`, `sqs-lambda-esm-cred-refresh-smoke.sh`, `stream-lambda-esm-cred-refresh-smoke.sh`, `sqs-lambda-queueurl-smoke.sh`, `sqs-lambda-fifo-esm-mc-smoke.sh` |
| `smokes/messaging/` | `sqs-*`, `sns-*`, `events-*`, `sfn-*`, `kinesis-*` |
| `smokes/networking/` | `vpc-*`, `sg-*`, `elbv2-*`, `route53-*`, `r53-*`, `vpce-*`, `egress-*`, `waf-*`, `network-firewall-*` |
| `smokes/compute/` | `ecs-*` (incl. `ecs-sqs-queueurl-smoke.sh`), `ec2-*`, `ecr-*`, `batch-*`, `autoscaling-*`, `application-autoscaling-*`, `apprunner-*`, `elasticbeanstalk-*`, `codedeploy-*` |
| `smokes/apigw/` | `apigw-*` |
| `smokes/data/` | `dynamodb-*`, `rds-*` |
| `smokes/transfer/` | `transfer-*` |
| `smokes/security/` | `kms-*`, `secrets-*`, `resource-policy-*`, `oidc-*`, `multi-account-*`, `acm-*`, `prowler-*`, `iam-access-denied.sh`, `iam-simulate-policy-smoke.sh`, `iam-permissions-boundary-key-smoke.sh`, `ec2-vpc-condition-keys-smoke.sh`, `api-call-log-*.sh` |
| `smokes/s3/` | `s3-*` (including `s3-parity.sh`) |
| `smokes/iac/` | `cfn-*`, `cdk-*`, `sam-*`, `serverless-*-smoke.sh`, `terraform-*`, `iac-smoke.sh` |
| `smokes/account/` | `mirror-*`, `custom-id-*`, `labels-*` |
| `smokes/parity/` | `aws-parity-*` |
| `smokes/logs/` | `logs-*` (CloudWatch Logs catalogue) |

`sqs-lambda-dlq-smoke.sh` / `sqs-lambda-esm-enable-smoke.sh` / `sqs-lambda-esm-cred-refresh-smoke.sh` / `stream-lambda-esm-cred-refresh-smoke.sh` / `sqs-lambda-queueurl-smoke.sh` are lambda, not messaging (`dlq`/`batch-failures`/`cred-refresh` need `python3` with `boto3`). WAF is networking (same milestone as VPC / ELB / DNS).

## Stay in `bin/`

Checks that are not smokes stay next to the tooling they support: `serverless-v3-fixture-check.sh`, `vpc-egress-bridge-check.sh`, `oidc-mint.py`.
