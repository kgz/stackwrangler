# Lambda → ECR image pull

`PackageType=Image` with `ImageUri` `…dkr.ecr.…/<repo>:<tag>` requires the function execution role to allow `ecr:BatchGetImage` before cold start. The URI rewrites to the local registry after that check.

**Status:** shipped

## Sequence

1. Create repository; push a Lambda base image the smoke expects.
2. CreateFunction with ECR `ImageUri` + role that allows `ecr:BatchGetImage` → invoke succeeds.
3. Sad: role without `ecr:BatchGetImage` → invoke fails before the handler.

## Prove it

```bash
./smokes/lambda/lambda-ecr-smoke.sh
```
