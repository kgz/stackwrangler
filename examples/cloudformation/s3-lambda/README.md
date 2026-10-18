# CloudFormation: S3 + Lambda (LocalEmu)

Same story as `examples/terraform/s3-lambda` — named bucket + Lambda that writes into it on `:4566`.

```bash
./bin/awsbox up --force
./bin/cfn-smoke.sh
```

Console General purpose buckets (SeaweedFS) will **not** show this bucket.
