# Dual S3 (SeaweedFS + LocalEmu)

Console and `aws --profile local` object UI hit **SeaweedFS** (`:8333`). Lambda / IaC / S3 events hit **LocalEmu S3** (`:4566`). Same account shape; two backends on purpose.

**Status:** partial · Docs: [s3-backends.md](https://github.com/kgz/stackwrangler/blob/main/docs/s3-backends.md) · Debt trail [#143](https://github.com/kgz/stackwrangler/issues/143)

## Sequence

1. `./bin/stackwrangler up` — both endpoints listening.
2. Console buckets list/objects → SeaweedFS.
3. Lambda or CFN that uses S3 → LocalEmu endpoint.
4. Smoke asserts the split; do not pretend one store.

## Prove it

```bash
./smokes/s3/s3-dual-endpoint-smoke.sh
```

## Console

![S3 buckets](/assets/console/home-s3-buckets.png)
