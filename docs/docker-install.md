# Public install (Docker image)

**Primary path for users who want to run the stack.** No `git clone`, no checkout-as-`$ROOT`, no `yarn` for the console.

Product CLI name: **stackwrangler** (`awsbox` remains a contributor shim in the repo).

## Layout choice (tradeoffs)

| Approach | Verdict |
|----------|---------|
| **Fat single container** (all processes in one image) | Rejected — LocalEmu needs host Docker for Lambda / EC2 / RDS backends; nesting those inside one PID namespace fights the sock model. |
| **Compose-in-container / DinD** | Rejected — nested daemon breaks Lambda/EC2 backends and doubles cost. |
| **Host-Docker orchestrator** (chosen) | One published orchestrator image mounts `/var/run/docker.sock`, runs Compose against the **host** engine, and pulls sibling images (patched LocalEmu, console nginx, ECR registry). Config + named volumes live under `~/.stackwrangler` (or `$STACKWRANGLER_HOME`). |

Honest limits of this shape:

- **Host Docker Engine required** (Compose v2). The orchestrator is not a substitute for Docker.
- **Socket mount** — the orchestrator (and LocalEmu) can manage containers on your daemon. Treat it like any privileged local-dev tool.
- **Published ports bind `127.0.0.1`** — fine on Linux; Docker Desktop / non-Linux networking may need docs from sibling Public OSS cards.
- **Dual S3** still applies: console buckets → SeaweedFS `:8333`; many IaC/Lambda paths → LocalEmu S3 `:4566` ([s3-backends.md](s3-backends.md)).
- Console image bakes default credentials (`stackwrangler` / `stackwranglerstackwrangler`). Changing keys in `~/.stackwrangler/.env` updates profile `local` but not the baked SPA until a custom console image rebuild (contributor `Dockerfile.console` build args).
- **Linux docker CLI inside LocalEmu** — contributor `docker-compose.yml` bind-mounts `${STACKWRANGLER_DOCKER_CLI:-/usr/bin/docker}` at `/usr/bin/docker` so LocalEmu can create VPC bridges and install ECS task-role DNAT. On Linux that default path is usually correct. Docker Desktop (macOS/Windows) ships a host-OS CLI that will **not** run inside the Linux LocalEmu container — download a static Linux `docker` binary for your CPU, point `STACKWRANGLER_DOCKER_CLI` at it, and recreate LocalEmu.

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) with Compose v2
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (for `aws --profile local`)

## Install (no git)

### One-liner (`docker run`)

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:latest
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:latest up
```

Console: <http://127.0.0.1:3000> · S3: `:8333` · LocalEmu: `:4566`

### Thin host CLI (release asset)

After a product tag has a GitHub Release (and publish-images uploaded the asset):

```bash
curl -fsSL -o stackwrangler \
  "https://github.com/kgz/stackwrangler/releases/latest/download/stackwrangler"
chmod +x stackwrangler
./stackwrangler up
./stackwrangler status
./stackwrangler console   # prints URL; console is already a compose service
```

Override image / data dir:

```bash
export STACKWRANGLER_IMAGE=ghcr.io/kgz/stackwrangler:v0.0.2
export STACKWRANGLER_HOME=$HOME/.stackwrangler
./stackwrangler up
```

## First-run config

On first `up`, the orchestrator copies defaults into `$STACKWRANGLER_HOME/.env` (same knobs as `.env.example`: ports, keys, region, account ids).

| Knob | Default | Notes |
|------|---------|--------|
| `STACKWRANGLER_S3_HOST_PORT` | `8333` | SeaweedFS |
| `STACKWRANGLER_LOCALEMU_HOST_PORT` | `4566` | LocalEmu gateway |
| `STACKWRANGLER_CONSOLE_HOST_PORT` | `3000` | nginx console |
| `STACKWRANGLER_ECR_HOST_PORT` | `5000` | distribution registry |
| `STACKWRANGLER_SFTP_HOST_PORT` | `2222` | Transfer native SFTP |
| `STACKWRANGLER_ACCESS_KEY` / `SECRET_KEY` | product defaults | also written into profile `local` |

Edit `~/.stackwrangler/.env`, then `stackwrangler down && stackwrangler up` (recreate). No git checkout for overrides.

Patches for LocalEmu are **baked into** `ghcr.io/kgz/stackwrangler-localemu` — you do not mount `localemu-patches/` on the public path. Contributor checkouts still use bind mounts via root `docker-compose.yml`.

## Upgrade

```bash
docker pull ghcr.io/kgz/stackwrangler:latest
docker pull ghcr.io/kgz/stackwrangler-localemu:latest
docker pull ghcr.io/kgz/stackwrangler-console:latest
docker pull ghcr.io/kgz/stackwrangler-ecr:latest
# or: pin :vX.Y.Z and STACKWRANGLER_IMAGE_TAG=vX.Y.Z
./stackwrangler up
```

Prefer digest pins for production-like machines (`docker buildx imagetools inspect ghcr.io/kgz/stackwrangler:vX.Y.Z`). Channels: `latest` (moving) and `vX.Y.Z` (release).

## Teardown

```bash
./stackwrangler down                 # stop containers; keep volumes + profile
./stackwrangler down -v              # also delete named volumes (state wipe)
./stackwrangler down --remove-profile -v
```

Or the same args via `docker run … ghcr.io/kgz/stackwrangler:latest down -v`.

## Images (GHCR)

| Image | Role |
|-------|------|
| `ghcr.io/kgz/stackwrangler` | Orchestrator CLI + release compose |
| `ghcr.io/kgz/stackwrangler-localemu` | LocalEmu + baked patches |
| `ghcr.io/kgz/stackwrangler-console` | Static Vite build + nginx `/aws-iam` proxy |
| `ghcr.io/kgz/stackwrangler-ecr` | `registry:2` + ECR notify config |

Published by [`.github/workflows/publish-images.yml`](../.github/workflows/publish-images.yml) on `v*.*.*` tags (and `workflow_dispatch`).

**Release ordering:** `bin/release-tag.sh` creates the GitHub Release **before** pushing the git tag, so the workflow can upload `install/stackwrangler`. The workflow also polls / creates the release if missing (needs `contents: write`) and retries the asset upload — a bare `git push --tags` still gets the CLI asset.

## Local build (before a tag / private GHCR)

From a **contributor** checkout only (building the artifact — not the public run path):

```bash
./bin/build-release-images.sh --tag local
export STACKWRANGLER_IMAGE=stackwrangler:local
export STACKWRANGLER_LOCALEMU_IMAGE=stackwrangler-localemu:local
export STACKWRANGLER_CONSOLE_IMAGE=stackwrangler-console:local
export STACKWRANGLER_ECR_IMAGE=stackwrangler-ecr:local
export STACKWRANGLER_LOCAL_IMAGES=1
# if host :5000 is taken:
export STACKWRANGLER_ECR_HOST_PORT=5050
export COMPOSE_PROJECT_NAME=stackwrangler-local
./install/stackwrangler up
```

Cold-machine check: Docker installed, **no** clone of this repo on the machine under test — only the built/pulled images + optional `install/stackwrangler` script.

## Limits vs full checkout

| | Image path | Contributor clone |
|--|------------|-------------------|
| Start stack | `docker run` / `install/stackwrangler` | `./bin/stackwrangler up` |
| Console | Baked nginx service | `./bin/stackwrangler console` (Vite) |
| LocalEmu patches | Baked in image | Live bind mounts |
| Smokes / OpenSpec / OD | Not shipped | Repo `smokes/`, `openspec/`, `design/` |
| `stackwrangler sls` / mirror | Not in image CLI | Checkout CLI |

## Related

- Root [README](../README.md) — newcomers pointed here first
- [CONTRIBUTING](../CONTRIBUTING.md) — clone path for development
- [public-release.md](public-release.md) — visibility flip (separate)
