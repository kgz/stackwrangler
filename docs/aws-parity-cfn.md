# Real-AWS CFN S3+Lambda parity

Same template as local: `examples/cloudformation/s3-lambda`.

```bash
./smokes/parity/aws-parity-cfn-s3-lambda.sh
```

1. LocalEmu `:4566` — deploy → invoke → object under `writes/` → delete  
2. Real AWS (default `~/.aws/credentials`, unset local `awsbox` env keys) — same → delete  

**Sad (empty Lambda role → AccessDenied):**

```bash
./smokes/parity/aws-parity-cfn-authz.sh
```

Template: `examples/cloudformation/s3-lambda-deny` (logs-only role).

**Cost:** short-lived S3 + Lambda + IAM — free-tier / noise if teardown succeeds.  
**Keep:** `AWSBOX_PARITY_KEEP=1`  
**One side:** `AWSBOX_PARITY_SKIP_LOCAL=1` or `AWSBOX_PARITY_SKIP_REAL=1`  
**Region (real):** `AWSBOX_PARITY_REGION` (default `ap-southeast-2`)
