# S3 backends (org-path single brain)

**Decision (#162):** the default org path uses **one** S3 brain — **LocalEmu** on `:4566` — for Transfer / Lambda / IaC **and** for console + `aws --profile local`. Silent cross-wire to SeaweedFS fails the v0.1.0 ship bar.

| Brain | Endpoint | Who uses it | Role |
|-------|----------|-------------|------|
| **LocalEmu S3** | `http://127.0.0.1:4566` | Console buckets UI, `aws --profile local`, Transfer, Lambda, CFN / CDK / SAM / Terraform, IAM deny labs | **Org-path brain** (required) |
| **SeaweedFS** | `http://127.0.0.1:8333` | Optional `./smokes/s3/s3-parity.sh` and keep-data volume checks | **Parity sidecar only** — not profile `local`, not console |

## Contract for org-path example / E2E (#780 / #781)

Assert all of the following against the **same** store:

| Surface | How to address LocalEmu S3 |
|---------|----------------------------|
| CLI | `aws --profile local s3 …` (services block `s3.endpoint_url` → `STACKWRANGLER_IAM_ENDPOINT`, default `:4566`) |
| Console | Buckets UI → `/aws-iam` proxy → LocalEmu (`VITE_S3_ENDPOINT=/aws-iam`) |
| IaC / runtime | `AWS_ENDPOINT_URL` / `--endpoint-url` → `http://127.0.0.1:4566` (or profile `local`) |
| Env | `STACKWRANGLER_IAM_ENDPOINT` (fallback `AWSBOX_IAM_ENDPOINT`) |

**Learner check:** put an object via Transfer / Lambda / `aws --profile local s3 cp` → it must appear in the console buckets list and in `aws --profile local s3 ls`. Success on SeaweedFS alone is the wrong store.

Do **not** point org-path tooling at `STACKWRANGLER_ENDPOINT` / `:8333`.

## Profiles

- `./bin/stackwrangler up` → profile `local` → **LocalEmu** for S3 and every other listed service (`STACKWRANGLER_IAM_ENDPOINT`, default `:4566`)
- `STACKWRANGLER_ENDPOINT` (default `:8333`) remains the SeaweedFS URL for optional parity smokes only

## Smoke

```bash
./smokes/s3/s3-org-path-brain-smoke.sh   # put on LocalEmu; visible via profile local; absent on Seaweed
./smokes/s3/s3-dual-endpoint-smoke.sh    # shim → org-path brain smoke (legacy name)
./smokes/s3/s3-parity.sh                 # optional SeaweedFS API breadth (not org path)
./smokes/s3/s3-persist-recreate-smoke.sh # PERSISTENCE=1 LocalEmu S3 recreate (#712)
```

Exit 0 of the org-path smoke means console/CLI/IaC share LocalEmu. If profile `local` still targets `:8333`, rewrite with `./bin/stackwrangler-profile write --force`.

## Persistence (LocalEmu S3, opt-in)

Default compose keeps `PERSISTENCE=0` so smokes stay hermetic. With `PERSISTENCE=1` and a volume on `/var/lib/localemu`:

- Bucket/object **metadata** lives under `/var/lib/localemu/state`
- Object **bodies** are snapshotted under `state/assets/s3_bodies` and restored after the S3 provider starts
- Runtime spool dirs live under `/var/lib/localemu/s3/<bucket>/` (not `/tmp/localemu-s3-storage`), and missing bucket dirs are recreated on restore so `PutObject` does not ENOENT

SeaweedFS still has `seaweed-data` / `seaweed-data-dev` for optional parity. `./bin/stackwrangler reset` wipes LocalEmu state (incl. LocalEmu S3) **and** both Seaweed volumes ([#200](https://github.com/kgz/stackwrangler/issues/200) · [dev-mode.md](dev-mode.md)).

## Console

S3 buckets UI hits LocalEmu via the same `/aws-iam` proxy as IAM/Lambda (`VITE_S3_ENDPOINT=/aws-iam`). No separate SeaweedFS browser endpoint on the org path.
