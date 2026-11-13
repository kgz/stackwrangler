# Terraform against stackwrangler

Point Terraform at LocalEmu (`AWSBOX_IAM_ENDPOINT`, default `http://127.0.0.1:4566`) so apply works with IAM on, remote state + DynamoDB lock, and a second plan that is empty.

Worked examples:

- [`examples/terraform/v002-tour/`](../examples/terraform/v002-tour/) — v0.0.2 public-path tour (SQS/SNS/Events/Kinesis/DynamoDB/Secrets/KMS/SFN/ECS/REST/RDS + Lambda/S3)
- [`examples/terraform/stackwrangler-backend/`](../examples/terraform/stackwrangler-backend/) — remote state + DynamoDB lock
- [`examples/terraform/s3-lambda/`](../examples/terraform/s3-lambda/) · [`ecs-nginx/`](../examples/terraform/ecs-nginx/)

Opt-in smoke: `./smokes/iac/terraform-backend-smoke.sh` (see Opt-in smoke).

Related: dual S3 brains in [s3-backends.md](s3-backends.md) — remote state for this flow uses **LocalEmu S3**, not SeaweedFS.

## Credentials (IAM enforced)

LocalEmu runs with IAM enforcement. The provider must use the product admin keys (defaults `stackwrangler` / `stackwranglerstackwrangler` from `.env` / GHCR install).

Placeholder keys such as `test` / `test` get a **403** from EC2 (and similar from other services) with a generic “security token invalid” style message — that is IAM rejecting the caller, not a missing endpoint.

```hcl
provider "aws" {
  access_key = "stackwrangler"
  secret_key = "stackwranglerstackwrangler"
  # …
}
```

## Provider endpoints

Wire every service you call. For shared-infra style stacks at least:

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "awsbox"
  secret_key                  = "awsboxawsbox"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2      = "http://127.0.0.1:4566"
    iam      = "http://127.0.0.1:4566"
    s3       = "http://127.0.0.1:4566"
    dynamodb = "http://127.0.0.1:4566"
    sts      = "http://127.0.0.1:4566"
  }
}
```

Add further service keys under `endpoints` as you use them (SNS, Lambda, …). Do not rely on instance metadata or real STS account lookup (`skip_*` above).

## S3 backend + override files

Terraform **`*_override.tf` replaces the entire `backend` block** — it does not merge attributes. If your production `backend "s3"` sets `bucket`, `key`, `dynamodb_table`, `encrypt`, etc., the override must **repeat every one of those**, then add LocalEmu bits:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-state-bucket"
    key            = "path/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "your-lock-table"
    encrypt        = true

    access_key = "awsbox"
    secret_key = "awsboxawsbox"

    endpoints = {
      s3       = "http://127.0.0.1:4566"
      dynamodb = "http://127.0.0.1:4566"
      sts      = "http://127.0.0.1:4566"
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
  }
}
```

Leaving out `use_path_style` or an endpoint usually sends traffic at real AWS hostnames or breaks path-style LocalEmu S3.

Backend settings cannot use input variables — copy `backend_override.tf.example` and edit names/URLs (the smoke does this for you).

## Bootstrap workspace first

Remote state needs the bucket and lock table to exist **before** `terraform init` of the app workspace.

1. Apply a small **bootstrap** root with **local** state that creates:
   - an S3 bucket (LocalEmu) for state objects
   - a DynamoDB table with hash key `LockID` (type `S`)
2. Write/generate the app `backend_override.tf` with those names
3. `terraform init` / `apply` the app root

See `examples/terraform/stackwrangler-backend/bootstrap/` then `…/app/`.

## Offline / isolated Docker network

When the emulator sits on an **internal** Docker network with no route to the public internet:

1. One-off `terraform init` (or `terraform providers mirror`) **with** registry access; keep the downloaded providers (e.g. under a plugin cache directory).
2. Attach the Terraform runner to the isolated network with the emulator.
3. Re-init / plan / apply with `-plugin-dir=<that cache>` so Terraform does not need `registry.terraform.io`.

Provider `endpoints` and backend `endpoints` must use the **emulator’s Docker DNS name and port on that network** (not only `127.0.0.1` from the host), still with path-style S3 and the same `skip_*` flags.

A post-`up` apply hook (below) must use the same isolation: run Terraform/serverless **on that network**, with endpoints aimed at the emulator — never a real account route.

## Dev apply hook (IaC as source of truth)

Saved emulator state can drift from wiring that does not round-trip. Prefer re-applying **your** Terraform / serverless after the stack is healthy, treating that IaC as the source of truth.

After `wait_healthy`, `./bin/stackwrangler up` runs an optional hook when configured (same path on the image CLI). A failing hook makes `up` exit non-zero with the error.

| Config | Meaning |
|--------|---------|
| `STACKWRANGLER_DEV_APPLY_HOOK` (or `AWSBOX_DEV_APPLY_HOOK`) | Path to one executable / bash script |
| `.awsbox/dev-apply-hook` (gitignored) | One script path per line (`#` comments ok); used when the env var is unset |
| `STACKWRANGLER_DEV_APPLY_HOOK_FILE` | Override path to that list file |

`--dev` mode selection is [#288](https://github.com/kgz/stackwrangler/issues/288) (not required yet). Today the hook runs whenever the env/config is set — keep it unset for hermetic smokes.

Example (copy outside the repo; no real account names):

```bash
cp examples/dev-apply/terraform-apply.example.sh ~/.stackwrangler/dev-apply.sh
chmod +x ~/.stackwrangler/dev-apply.sh
export STACKWRANGLER_DEV_APPLY_HOOK=$HOME/.stackwrangler/dev-apply.sh
./bin/stackwrangler up
```

**Idempotency:** a second `up` with the same hook should apply with no changes when state and IaC agree. If they disagree (manual console edits, partial apply, wiped LocalEmu with leftover remote state), Terraform/serverless reports the drift — fix IaC or state; the hook does not auto-reconcile beyond a normal apply.

**Unit smoke (no Docker):** `./smokes/iac/dev-apply-hook-smoke.sh`

## Clean apply + empty second plan

After bootstrap + override:

```bash
cd examples/terraform/stackwrangler-backend/app
terraform init -input=false
terraform apply -input=false -auto-approve
terraform plan -input=false -detailed-exitcode
# exit 0 = no changes
```

## Opt-in smoke

Not part of `./bin/e2e.sh`. Requires LocalEmu up and an explicit opt-in:

```bash
./bin/stackwrangler up
AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh
```

The script:

1. Refuses to run unless `AWSBOX_TERRAFORM_BACKEND_SMOKE=1`
2. Runs a **canary** `sts get-caller-identity` **without** a local endpoint; if that call **succeeds**, it aborts (real AWS credentials/route would be used)
3. Bootstraps state bucket + lock table, applies the app workspace, asserts a second plan is no-change

## Manual walkthrough

```bash
./bin/stackwrangler up
cd examples/terraform/stackwrangler-backend/bootstrap
terraform init
terraform apply -auto-approve \
  -var="state_bucket=awsbox-tf-state-demo" \
  -var="lock_table=awsbox-tf-locks-demo"

cd ../app
# copy example override; set bucket/table/endpoint to match bootstrap + LocalEmu
cp backend_override.tf.example backend_override.tf
# edit STATE_BUCKET / LOCK_TABLE (and endpoint if not 127.0.0.1:4566)
terraform init
terraform apply -auto-approve
terraform plan -detailed-exitcode   # expect 0
```
