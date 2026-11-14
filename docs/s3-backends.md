# Dual S3 backends (intentional near-term)

awsbox runs **two** S3 APIs on purpose until a later unify. Do not expect one bucket list to cover both.

| Brain | Endpoint | Who uses it | Why |
|-------|----------|-------------|-----|
| **SeaweedFS** | `http://127.0.0.1:8333` | Console general-purpose S3, `aws --profile local` | Real object store + CORS for browser |
| **LocalEmu S3** | `http://127.0.0.1:4566` | Lambda / CFN / CDK / SAM / Transfer bridge / IAM deny lab | Same process as IAM (`IAM_ENFORCEMENT=1`) |

**Decision (#143):** keep the split for now. Document it; smoke it. Full unify (single brain for console + IaC) is a later project, not silent.

## Profiles

- `./bin/stackwrangler up` → profile `local` → **SeaweedFS** (`AWSBOX_ENDPOINT`, default `:8333`)
- IaC / authz smokes → `--endpoint-url` **LocalEmu** (`AWSBOX_IAM_ENDPOINT`, default `:4566`)

## Smoke

```bash
./smokes/s3/s3-dual-endpoint-smoke.sh   # create on each; assert the other cannot see it
./smokes/s3/s3-persist-recreate-smoke.sh  # PERSISTENCE=1 + volume: objects + PutObject after recreate (#712)
```

Exit 0 only while the stores stay separate. If this starts failing, something merged the backends — update this doc before celebrating.

## Persistence (LocalEmu S3, opt-in)

Default compose keeps `PERSISTENCE=0` so smokes stay hermetic. With `PERSISTENCE=1` and a volume on `/var/lib/localemu`:

- Bucket/object **metadata** lives under `/var/lib/localemu/state`
- Object **bodies** are snapshotted under `state/assets/s3_bodies` and restored after the S3 provider starts
- Runtime spool dirs live under `/var/lib/localemu/s3/<bucket>/` (not `/tmp/localemu-s3-storage`), and missing bucket dirs are recreated on restore so `PutObject` does not ENOENT

SeaweedFS already has `seaweed-data` / `seaweed-data-dev`. `./bin/stackwrangler reset` wipes LocalEmu state (incl. LocalEmu S3) **and** both Seaweed volumes ([#200](https://github.com/kgz/stackwrangler/issues/200) · [dev-mode.md](dev-mode.md)).

## Console

S3 buckets UI hits SeaweedFS only (`VITE_S3_ENDPOINT`). Lambda/IAM UI hits LocalEmu (`VITE_IAM_ENDPOINT` / `/aws-iam` proxy).
