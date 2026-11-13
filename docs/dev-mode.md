# Test vs dev mode

stackwrangler serves two jobs that fight each other: hermetic smokes (throwaway state) and an always-on local stack (state that survives `down` / `up`). Modes keep those paths separate.

| Mode | Flag | Persistence | Use |
|------|------|-------------|-----|
| **test** (default) | `./bin/stackwrangler up` or `up --test` | Off (`PERSISTENCE=0`). Seaweed named volume `seaweed-data`. No LocalEmu/ECR bind mounts. | Smokes, CI-like local runs, clean IAM/IaC experiments |
| **dev** | `./bin/stackwrangler up --dev` | On. LocalEmu → `.awsbox/dev/localemu`, ECR blobs → `.awsbox/dev/ecr`, Seaweed volume `seaweed-data-dev`. | Warm restart local infra; keep deployed stacks across compose recreates |

`status` prints the recorded mode (file: `.awsbox/mode`).

## Lifecycle

```bash
./bin/stackwrangler up --dev    # record mode=dev, start with persistence
./bin/stackwrangler down        # containers stop; dev volumes + .awsbox/dev kept
./bin/stackwrangler up --dev    # same data comes back
./bin/stackwrangler reset       # deliberate wipe (see below), mode → test
```

Switching mode never silently reuses the other mode’s volumes or bind mounts. If the stack is still up, `up --test` after `--dev` (or the reverse) errors until you `down`.

Env the CLI sets (prefer `STACKWRANGLER_*`; `AWSBOX_*` still accepted as fallbacks where wired):

- `STACKWRANGLER_MODE` — `test` | `dev`
- `STACKWRANGLER_PERSISTENCE` — `0` | `1` (maps to LocalEmu `PERSISTENCE`)
- `STACKWRANGLER_SEAWEED_VOLUME` — `seaweed-data` | `seaweed-data-dev`

Compose: base `docker-compose.yml` +, for `--dev` only, `docker-compose.dev.yml`.

Do not set `STACKWRANGLER_PERSISTENCE=1` alone in `.env` for day-to-day use — without the `--dev` bind mounts, LocalEmu still writes into the container filesystem and a recreate loses it. Use `up --dev` (or a compose override that mounts `/var/lib/localemu` the same way).

## What `reset` wipes

| Store | Path / name | Wiped? |
|-------|-------------|--------|
| LocalEmu API state + S3 spool | `.awsbox/dev/localemu` | yes |
| ECR registry blobs | `.awsbox/dev/ecr` | yes |
| SeaweedFS (test + dev) | `seaweed-data`, `seaweed-data-dev` (+ project-prefixed) | yes |
| Compose project volumes | `<project>_*` | yes (best-effort) |
| RDS engine containers | `localemu-rds-<id>` | yes |
| RDS data volumes | `localemu-rds-<id>-data` | yes |

Mode is set back to `test` after reset.

## Per-service persistence table (#200)

What survives a LocalEmu **container recreate** when `--dev` / `PERSISTENCE=1` + the state volume are in place:

| Service / store | Across recreate | Across `down`/`up --dev` | Lost / notes |
|-----------------|-----------------|--------------------------|--------------|
| LocalEmu S3 (IaC / `:4566`) | **Persisted** (metadata + `s3_bodies`) | same | Separate from Seaweed — [s3-backends.md](s3-backends.md) |
| SeaweedFS S3 (`:8333`) | N/A (own container) | **Persisted** (`seaweed-data-dev`) | Wiped by `reset` |
| IAM / STS | **Persisted** | same | |
| Secrets Manager | **Persisted** | same | |
| SSM Parameter Store | **Persisted** | same | |
| DynamoDB | **Persisted** | same | |
| Lambda (metadata + code bodies) | **Persisted** when `s3_bodies` intact; invoke works after recreate | same | If code blobs wiped → `Failed` until `UpdateFunctionCode` ([#713](https://github.com/kgz/stackwrangler/issues/713)) |
| SQS event source mappings | **Persisted**; orphans deletable ([#717](https://github.com/kgz/stackwrangler/issues/717)) | same | |
| ECR images (registry:2) | **Persisted** (`.awsbox/dev/ecr`) | same | Moto ECR catalog resyncs from registry ([#684](https://github.com/kgz/stackwrangler/issues/684)) |
| RDS (Postgres / MySQL / Aurora) | **Persisted** — Docker volume `localemu-rds-<id>-data`; host port + creds restored from LocalEmu state ([#705](https://github.com/kgz/stackwrangler/issues/705)) | same (containers may stop on `down`; volume kept) | `delete-db-instance` removes the volume; `reset` removes all `localemu-rds-*` |
| ECS tasks | API state persisted; containers **reconciled** on load ([#716](https://github.com/kgz/stackwrangler/issues/716)) | stopped containers may resume | Missing container → STOPPED |
| EC2 / VPC networks | API state persisted; Docker networks **re-created** lazily | same | iptables / SG rules re-applied by patches |
| Console labels | file outside compose | kept if on disk | gitignored `labels.yaml` |

Prove multi-service recreate: `./smokes/platform/persist-recreate-smoke.sh`. Dev keep-data + reset: `./smokes/platform/mode-dev-keep-data-smoke.sh`. RDS host port: `./smokes/data/rds-host-port-restart-persist-smoke.sh`.

## Related

- Epic: dev mode (#291) · warm restart (#289) · IaC re-apply on up (#290) · mode CLI (#288) · persistence productization (#200)
