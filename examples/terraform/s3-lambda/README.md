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

Console General purpose buckets and `aws --profile local` use the same LocalEmu S3 brain as this bucket ([s3-backends.md](../../../docs/s3-backends.md)).
