# Use cases

Paths we stage as a **local AWS-shaped account** — same tools as real AWS, hardened defaults, honest depth.

| Use case | Path |
|----------|------|
| [OpenTofu → Expo + IAM](./opentofu-expo-iam) | Terraform/OpenTofu → VPC → Lambda / EC2 → SNS → Expo, with strict IAM and Secrets Manager |
| [Org path (Transfer → … → RDS)](./org-path) | SFTP ingest → Lambda → S3 → ECS → RDS — **partial** today; full E2E coming in v0.1.0 ([#781](https://github.com/kgz/stackwrangler/issues/781)) |

See [Vision](../vision) and [Completeness](../completeness) for depth tags.

Compare emulators and alternatives: [Compare](../compare/).
