# Org-path S3 (single LocalEmu brain)

Console, `aws --profile local`, Transfer / Lambda / IaC all use **LocalEmu S3** (`:4566`). SeaweedFS (`:8333`) is optional parity only — not the learner path.

**Status:** working · Docs: [s3-backends.md](https://github.com/kgz/stackwrangler/blob/main/docs/s3-backends.md) · [#162](https://github.com/kgz/stackwrangler/issues/162)

## Sequence

1. `./bin/stackwrangler up` — profile `local` S3 → LocalEmu.
2. Console buckets list/objects → LocalEmu (via `/aws-iam` proxy).
3. Lambda / CFN / Transfer that uses S3 → same LocalEmu endpoint.
4. Smoke asserts put via LocalEmu is visible on `aws --profile local` and absent on Seaweed.

## Prove it

```bash
./smokes/s3/s3-org-path-brain-smoke.sh
```

## Console

![S3 buckets](/assets/console/home-s3-buckets.png)
