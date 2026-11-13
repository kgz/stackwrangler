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

## What `reset` wipes today

- `.awsbox/dev/` (LocalEmu state dir + ECR registry data)
- Seaweed named volumes `seaweed-data` and `seaweed-data-dev` (and this compose project’s prefixed copies)
- Best-effort other volumes named for this compose project

## Deferred to [#200](https://github.com/kgz/stackwrangler/issues/200)

Full persistence productization beyond mode selection:

- Per-engine RDS Docker volumes (survive LocalEmu recreate; define `delete-db-instance` vs volume)
- Workload reconcile (ECS/Lambda/EC2 containers vs persisted API state)
- VPC network / iptables re-apply after recreate
- LocalEmu S3 (IaC backend) vs Seaweed dual-store matrix
- Public image / `compose.release.yml` persistence knobs

This ticket (#288) lands the mode CLI and the compose wiring that exists today; #200 owns the deep volume matrix and round-trip smoke table.

## Related

- Epic: dev mode (#291) · warm restart (#289) · IaC re-apply on up (#290) · persistence (#200)
