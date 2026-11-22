# CloudFormation: S3 + Lambda (LocalEmu)

Same story as `examples/terraform/s3-lambda` — named bucket + Lambda that writes into it on `:4566`.

```bash
./bin/awsbox up --force
./smokes/iac/cfn-smoke.sh
```

Console General purpose buckets and `aws --profile local` use the same LocalEmu S3 brain as this bucket.
