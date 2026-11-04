# ECS task → ECR image pull

Task definition image `…dkr.ecr.…/<repo>:<tag>` requires the execution role to allow `ecr:BatchGetImage` (and related). Push/pull also via local registry hostname in some paths.

**Status:** partial · Gaps: push via repositoryUri hostname [#218](https://github.com/kgz/stackwrangler/issues/218) · console [#217](https://github.com/kgz/stackwrangler/issues/217)

## Sequence

1. Create repository; push an image the smoke expects.
2. Run ECS task with ECR URI + execution role.
3. Sad: role without `ecr:BatchGetImage`.

## Prove it

```bash
./bin/ecr-smoke.sh
```
