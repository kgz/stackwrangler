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

Compose: base `docker-compose.yml` +, for `--dev` only, `docker-compose.dev.yml`. Dev mode sets `restart: unless-stopped` on core services (S3, LocalEmu, ECR registry + hostname, and profile-gated sftp / aws-redirect) so the stack returns after Docker/WSL restart ([#748](https://github.com/kgz/stackwrangler/issues/748) · [#763](https://github.com/kgz/stackwrangler/issues/763)). Ephemeral `--test` keeps the default `no`. RDS engine containers LocalEmu creates under `PERSISTENCE=1` get the same policy (start.d hook); ECS task resume after reboot is separate ([#716](https://github.com/kgz/stackwrangler/issues/716) / [#747](https://github.com/kgz/stackwrangler/issues/747)).

### Compose overrides (#748)

`up` / `down` / `status` rebuild the compose file list via `refresh_compose`. Do **not** assign `COMPOSE=(…)` in a wrapper and expect it to stick — it is overwritten. Use one of:

| Mechanism | When |
|-----------|------|
| `docker-compose.override.yml` (repo root) | Auto-merged when the file exists (gitignored) |
| `.awsbox/compose.local.yml` | Auto-merged; stays under gitignored `.awsbox/` |
| `STACKWRANGLER_COMPOSE_EXTRA` | Space-separated extra `-f` files (also `AWSBOX_COMPOSE_EXTRA`) |
| `STACKWRANGLER_COMPOSE_OVERRIDE` | Single extra file (alias; also `AWSBOX_COMPOSE_OVERRIDE`) |

Merge order (later wins): base → `docker-compose.dev.yml` (dev) → `override.yml` → `compose.local.yml` → `COMPOSE_EXTRA` → `COMPOSE_OVERRIDE`.

```bash
# example: persist + restart tweaks for a staging wrapper
export STACKWRANGLER_COMPOSE_EXTRA=/path/to/my-override.yml
./bin/stackwrangler up --dev

# inspect the merged model without starting anything
./bin/stackwrangler compose-config dev | less
```

Smoke: `./smokes/platform/up-compose-extra-smoke.sh` (dry always; `STACKWRANGLER_748_LIVE=1` for destructive `up`).

LocalEmu runs as uid 1000 inside its container. A boot hook gives `.awsbox/dev/localemu` to that user on start, so `up --dev` works whichever uid runs the CLI (#754). Files there end up owned by uid 1000 on the host; `reset` removes them through a container when your user can't.

Do not set `STACKWRANGLER_PERSISTENCE=1` alone in `.env` for day-to-day use — without the `--dev` bind mounts, LocalEmu still writes into the container filesystem and a recreate loses it. Use `up --dev` (or a compose override that mounts `/var/lib/localemu` the same way).

## Warm restart ([#289](https://github.com/kgz/stackwrangler/issues/289))

Goal: `down` then `up --dev` reuses prebuilt images and stopped workload containers instead of rebuilding/recreating everything.

| Piece | Behaviour |
|-------|-----------|
| **Prebuilt images** | `up` ensures `localemu/ec2-base:v4` (sshd + iptables) and `localemu/awsbox-rt:latest` (SG/route netns sidecar) from `docker/Dockerfile.ec2-base` + `docker/Dockerfile.awsbox-rt` (same files LocalEmu builds from). No `apk`/`apt` into workload containers on private VPC nets. |
| **SG iptables** | Probe-only in the workload; missing iptables → alpine sidecar (never package-install at task start). |
| **VPC cleanup** | In `--dev`, `localemu-ec2-*` / `localemu-ecs-*` / `localemu-rds-*` are left for `docker start`. Empty orphan `localemu-vpc-*` bridges are still removed. `reset` force-reclaims. |
| **Networks kept** | `down` in `--dev` removes containers but keeps compose networks, so preserved bridge-mode ECS tasks reattach on `up --dev` (#753). `reset` removes them. |
| **Graceful down** | `down` in `--dev` stops LocalEmu with a long grace window (`stop_grace_period` / `STACKWRANGLER_LOCALEMU_STOP_TIMEOUT`, default 90s) so `ON_SHUTDOWN` persistence finishes before compose removes the container. |
| **ECS reconcile** | Persisted RUNNING tasks: resume stopped containers or mark STOPPED when missing ([#716](https://github.com/kgz/stackwrangler/issues/716)). |
| **EC2 reconcile** | LocalEmu `on_after_state_load` resumes stopped `localemu-ec2-*` from recorded state. |

Smoke: `./smokes/platform/warm-restart-smoke.sh` (offline Docker checks always; live LocalEmu when reachable, or `AWSBOX_WARM_RESTART_SKIP_LIVE=1`). Timed multi-workload restart SLA stays on [#200](https://github.com/kgz/stackwrangler/issues/200).

## What `reset` wipes

| Store | Path / name | Wiped? |
|-------|-------------|--------|
| LocalEmu API state + S3 spool | `.awsbox/dev/localemu` | yes |
| ECR registry blobs | `.awsbox/dev/ecr` | yes |
| SeaweedFS (test + dev) | `seaweed-data`, `seaweed-data-dev` (+ project-prefixed) | yes |
| Compose project volumes | `<project>_*` | yes (best-effort) |
| RDS engine containers | `localemu-rds-<id>` | yes |
| RDS data volumes | `localemu-rds-<id>-data` | yes |

Mode is set back to `test` after reset. Force cleanup also removes preserved workload containers + orphan VPC bridges.

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
| Lambda (metadata + code bodies) | **Persisted** when `s3_bodies` intact; invoke works after recreate ([#751](https://github.com/kgz/stackwrangler/issues/751)) | same | If code blobs wiped → `Failed` until `UpdateFunctionCode` ([#713](https://github.com/kgz/stackwrangler/issues/713)) |
| SQS event source mappings | **Persisted**; orphans deletable ([#717](https://github.com/kgz/stackwrangler/issues/717)) | same | |
| ECR images (registry:2) | **Persisted** (`.awsbox/dev/ecr`) | same | Moto ECR catalog resyncs from registry ([#684](https://github.com/kgz/stackwrangler/issues/684)) |
| RDS Postgres | **Persisted** (smoked) — volume `localemu-rds-<id>-data`; host port + SQL row survive restart/recreate ([#705](https://github.com/kgz/stackwrangler/issues/705)) | same (containers may stop on `down`; volume kept) | `delete-db-instance` removes the volume; `reset` removes all `localemu-rds-*` |
| RDS MySQL / Aurora MySQL | **Persisted** (smoked) — MySQL instance + Aurora writer/reader SQL + cluster endpoints survive hard recreate (`docker rm` sidecars; volumes + meta kept) ([#743](https://github.com/kgz/stackwrangler/issues/743)) | same (containers may stop on `down`; volume kept) | `delete-db-instance` / `delete-db-cluster` removes volumes; `reset` removes all `localemu-rds-*` |
| ECS tasks | API state persisted; containers **reconciled** on load ([#716](https://github.com/kgz/stackwrangler/issues/716)) | stopped containers may resume | Missing container → STOPPED |
| EC2 / VPC networks | API state persisted; Docker networks **re-created** lazily; `--dev` keeps stopped EC2 containers for warm restart ([#289](https://github.com/kgz/stackwrangler/issues/289)) | same | iptables / SG rules re-applied by patches |
| ELBv2 | API state persisted; listeners / rules / targets **rebuilt** on load (sockets, ACM TLS, VPC join) ([#770](https://github.com/kgz/stackwrangler/issues/770)) | same | Targets are external (EC2/IP containers); smoke keeps the IP target alive across restart |
| Console labels | file outside compose | kept if on disk | gitignored `labels.yaml` |

Prove multi-service recreate: `./smokes/platform/persist-recreate-smoke.sh`. Dev keep-data + reset: `./smokes/platform/mode-dev-keep-data-smoke.sh`. Reset RDS wipe (containers/volumes): `./smokes/platform/mode-reset-rds-wipe-smoke.sh`. RDS Postgres host port + SQL: `./smokes/data/rds-host-port-restart-persist-smoke.sh`. RDS MySQL / Aurora SQL after recreate: `./smokes/data/rds-mysql-persist-recreate-smoke.sh`, `./smokes/data/rds-aurora-mysql-persist-recreate-smoke.sh` ([#743](https://github.com/kgz/stackwrangler/issues/743)). ELBv2 restart: `./smokes/networking/elbv2-persist-restart-smoke.sh` ([#770](https://github.com/kgz/stackwrangler/issues/770)). Warm restart images/preserve: `./smokes/platform/warm-restart-smoke.sh` ([#289](https://github.com/kgz/stackwrangler/issues/289); timed SLA on [#200](https://github.com/kgz/stackwrangler/issues/200)). Terraform empty-plan-after-recreate: `./smokes/iac/terraform-backend-persist-recreate-smoke.sh` ([#742](https://github.com/kgz/stackwrangler/issues/742)).

## Related

- Epic: dev mode (#291) · warm restart (#289) · IaC re-apply on up (#290) · mode CLI (#288) · persistence productization (#200)
