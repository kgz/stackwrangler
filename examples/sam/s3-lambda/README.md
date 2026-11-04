# SAM: S3 + Lambda (LocalEmu)

`template.yaml` is a normal SAM app (`AWS::Serverless::Function`).

`./smokes/iac/sam-smoke.sh` packages the zip and deploys `packaged-template.yaml` (resolved CFN, no Transform) to LocalEmu — works without the SAM CLI. With SAM installed you can also:

```bash
sam build
sam deploy --stack-name … --parameter-overrides … \
  --region us-east-1 \
  # point tooling at http://127.0.0.1:4566
```

```bash
./bin/awsbox up --force
./smokes/iac/sam-smoke.sh
```
