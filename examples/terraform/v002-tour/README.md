# Terraform: v0.0.2 public-path tour

One apply creates LocalEmu resources that match the **v0.0.2** console/list surfaces (and related task-role / messaging depth). Aimed at the GHCR install path — not a git clone.

## Prerequisites

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:v0.0.2
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:v0.0.2 up
```

Console web app: <http://127.0.0.1:3000> · APIs: `:4566` · profile `local`.

Terraform ≥ 1.5 + AWS provider 5.x.

## Apply

```bash
cd examples/terraform/v002-tour
terraform init
terraform apply -auto-approve
# skip Docker Postgres (faster):
# terraform apply -auto-approve -var=create_rds=false
```

Defaults use product keys `stackwrangler` / `stackwranglerstackwrangler` against `http://127.0.0.1:4566`.

## What it covers (v0.0.2 map)

| Surface | Resource | Issue |
|---------|----------|-------|
| S3 + Lambda | `aws_s3_bucket`, `aws_lambda_function` | hosting path |
| SQS / SNS fan-out | queue + topic + subscription | #167 · #172 |
| EventBridge schedule → SNS | `aws_cloudwatch_event_rule` | #173 |
| Kinesis stream | `aws_kinesis_stream` | #178 |
| DynamoDB table | `aws_dynamodb_table` | #174 |
| Secrets + KMS | secret encrypted with CMK | #176 · #177 |
| Step Functions | Pass state machine | #175 |
| ECS cluster + task role | cluster, task def, `task_role_arn` | #146 · #154 / #254 |
| API Gateway REST | REST API + MOCK `GET /ping` + stage | #189 |
| RDS Postgres | `aws_db_instance` (optional) | #145 |

CFN console Create/Update/StackSets (#93–#95) are console-only here — use the console wizards or `examples/cloudformation/`.

SeaweedFS console buckets (`:8333`) are separate from this LocalEmu S3 bucket ([s3-backends.md](../../../docs/s3-backends.md)).

## After apply

```bash
aws --profile local --endpoint-url http://127.0.0.1:4566 \
  lambda invoke --function-name "$(terraform output -raw lambda_function)" \
  --cli-binary-format raw-in-base64-out --payload '{}' /tmp/out.json && cat /tmp/out.json

aws --profile local --endpoint-url http://127.0.0.1:4566 \
  sns publish --topic-arn "$(terraform output -raw sns_topic_arn)" --message hello
```

Open the console lists linked in `terraform output list_in_console`.

## Destroy

```bash
terraform destroy -auto-approve
# RDS: may take a minute while the engine container stops
```
