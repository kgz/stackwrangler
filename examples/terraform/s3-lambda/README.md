# Terraform: S3 + Lambda (LocalEmu)

Creates a **named bucket** and a **Lambda that writes into it** on LocalEmu (`:4566`).

```bash
# from repo root
./bin/awsbox up --force
./smokes/iac/iac-smoke.sh
# or manually:
cd examples/terraform/s3-lambda
terraform init
terraform apply -auto-approve -var="bucket_name=my-demo-bucket"
```

Console General purpose buckets (SeaweedFS) will **not** show this bucket — IaC S3 lives on LocalEmu until backends are unified.
