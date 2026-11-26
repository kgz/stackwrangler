# Prowler, Steampipe & diagrammers

Run **existing** AWS security scanners and inventory/diagram tools against a local account — without requesting read-all keys on production.

**Status:** partial · Prowler is smoked; Steampipe / diagrammers work via the same endpoint pattern (not every plugin is parity-proven).

## Why

AppSec and platform teams often cannot (or should not) hand CI a production `ReadOnlyAccess` key just to dry-run Prowler or Steampipe. Point those tools at stackwrangler (`IAM_ENFORCEMENT=1` on LocalEmu) and iterate locally first.

## Shared connection

```bash
./bin/stackwrangler up   # or public docker Full Mode — see Getting Started

export AWS_ACCESS_KEY_ID=stackwrangler
export AWS_SECRET_ACCESS_KEY=stackwranglerstackwrangler
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
```

Prefer **`AWS_ENDPOINT_URL`** (no host `~/.aws` edits). Profile `local` is optional.

## Prowler

Preferred path — already wired for S3 Control virtual-hosts and a failing-API baseline:

```bash
./bin/stackwrangler hosts check   # apply if needed (awsbox.localhost)
./smokes/security/prowler-smoke.sh
```

Manual (same idea as the smoke; use `env -i` so real credentials cannot leak):

```bash
export AWS_ENDPOINT_URL=http://awsbox.localhost:4566
prowler aws --log-level ERROR -f us-east-1 --scan-unused-services
```

Do **not** use `http://127.0.0.1:4566` for Prowler — S3 Control’s `<account-id>.127.0.0.1` host form does not resolve. Details: [docs/prowler.md](https://github.com/kgz/stackwrangler/blob/main/docs/prowler.md).

## Steampipe

Same endpoint + keys. Example:

```bash
export AWS_ENDPOINT_URL=http://127.0.0.1:4566
steampipe query "select name, arn from aws_s3_bucket"
steampipe query "select name, runtime from aws_lambda_function"
```

Plugin coverage depends on which describe APIs LocalEmu implements for that service — treat empty or error rows as a Completeness gap, not a Steampipe bug. Prefer org-path services we claim Working / Partial.

## Diagrammers / inventory CLIs

Anything that speaks the AWS SDK against a custom endpoint works the same way:

```bash
export AWS_ENDPOINT_URL=http://127.0.0.1:4566
# e.g. former2, cloudmapper-style collectors, custom inventory scripts
aws s3 ls
aws lambda list-functions
aws ecs list-clusters
```

Stage a small stack first (OpenTofu / console / CLI) so the diagram has edges worth drawing.

## Honest limits

| Tool | What we claim |
|------|----------------|
| Prowler | Scoped scan + smoke baseline — not full-catalog parity |
| Steampipe | Endpoint works; per-table fidelity follows Completeness |
| Diagrammers | Inventory of what exists locally — not a substitute for prod topology |

Not a production scanner replacement. Pre-flight posture and inventory before CTO / staging.

Next: [Getting Started](../getting-started) · [OpenTofu → Expo + IAM](./opentofu-expo-iam) · [Compare](../compare/) · [Completeness](../completeness)
