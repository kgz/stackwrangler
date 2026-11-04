# Terraform: S3 backend + lock on LocalEmu

Bootstrap creates a **state bucket** and **DynamoDB lock table** (local state). The app workspace uses an S3 backend via `backend_override.tf` and creates a tiny SNS topic.

Full notes: [docs/terraform-stackwrangler.md](../../../docs/terraform-stackwrangler.md).

```bash
./bin/awsbox up
AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh
```

Manual: apply `bootstrap/` first, copy `app/backend_override.tf.example` → `app/backend_override.tf`, fill bucket/table names, then `terraform init && apply` under `app/`.
