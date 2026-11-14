# ECS task → ECR image pull

Task definition image `…dkr.ecr.…/<repo>:<tag>` requires the execution role to allow `ecr:BatchGetImage` (and related) on that repository ARN (`arn:aws:ecr:…:repository/<name>` — not the account `*`) ([#709](https://github.com/kgz/stackwrangler/issues/709)). `docker login` / `push` / `pull` of that same `repositoryUri` hostname works via the `ecr-hostname` TLS edge (`./bin/stackwrangler-hosts ecr-apply`); loopback `127.0.0.1:5000` remains for ECS rewrite ([#218](https://github.com/kgz/stackwrangler/issues/218)). BuildKit provenance pushes an OCI image **index**; the registry push hook records that tag the same as a plain manifest ([#683](https://github.com/kgz/stackwrangler/issues/683)). After a LocalEmu restart with `PERSISTENCE=0`, moto ECR is empty but the registry volume still has blobs — startup catalog resync (and `create-repository` adopt) re-records tags so a no-op re-push is not required ([#684](https://github.com/kgz/stackwrangler/issues/684)).

**Status:** partial · Gaps: console [#217](https://github.com/kgz/stackwrangler/issues/217)

## Sequence

1. Create repository; `ecr-apply` hosts + docker CA; push via `repositoryUri` (and/or loopback), including an OCI index tag.
2. Run ECS task with ECR URI + execution role scoped to that repository ARN.
3. Sad: same role against another repository; role without `ecr:BatchGetImage`.

## Prove it

```bash
./smokes/compute/ecr-smoke.sh
```
