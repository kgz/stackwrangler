# Getting Started

Bring up a local AWS-shaped account, open the console, and talk to it with the AWS CLI.

**Not affiliated with Amazon Web Services.** stackwrangler is independent OSS: test locally, then deploy to real AWS. New here? Start with [Why](./why).

## Prerequisites

- Docker Engine on Linux (Compose v2). Published ports bind to `127.0.0.1` on that host. Windows users: run Linux via WSL with Docker Desktop WSL integration or an engine inside WSL.
- AWS CLI v2

No git clone for the public path. Full reference: [docker-install.md](https://github.com/kgz/stackwrangler/blob/main/docs/docker-install.md) in the repo.

## 1. Start the stack (Docker image)

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:latest
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:latest up
```

Pin a cut with `:v0.0.2` (or a digest) instead of `:latest` — see [Changelog](./changelog) and [docker-install.md](https://github.com/kgz/stackwrangler/blob/main/docs/docker-install.md).

That pulls sibling images (LocalEmu with patches, SeaweedFS, **console web app**, ECR registry), starts them on the **host** Docker engine, and writes AWS profile `local`. Config lives in `~/.stackwrangler`. One `up` = APIs + CLI profile + web console — no extra step for the UI.

Tear down with the same image and `down` (thin CLI: `stackwrangler down`; optional `--remove-profile` drops profile `local`).

::: tip Naming
**stackwrangler** is the product CLI and docs brand. **LocalEmu** is the emulator behind `:4566`. This is unrelated to Cloudflare’s Wrangler CLI.
:::

## 2. Open the console

Browse <http://127.0.0.1:3000> — already running after `up` (baked static console on the release nginx image; no Vite).

Grey-rose chrome, same account as the CLI. Home opens on **S3 general purpose buckets** (SeaweedFS):

![Console home — S3 buckets](/assets/console/home-s3-buckets.png)

## 3. Use the AWS CLI

::: code-group

```bash [S3 (SeaweedFS)]
aws --profile local s3 ls
```

```bash [Lambda (LocalEmu)]
aws --profile local \
  --endpoint-url http://127.0.0.1:4566 \
  lambda list-functions
```

:::

Profile `local` points S3 at SeaweedFS (`:8333`). Most other services use LocalEmu (`:4566`). See [Concepts](./concepts) for the dual-S3 split.

## 4. Upgrade / teardown

```bash
docker pull ghcr.io/kgz/stackwrangler:latest   # and sibling :latest tags — see docker-install
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:latest down -v
```

## Contributors only

Clone the repo when changing the product (smokes, patches, console source). See [CONTRIBUTING](https://github.com/kgz/stackwrangler/blob/main/CONTRIBUTING.md) — not required to run or upgrade.

## 5. Next

- [Compare](./compare/) — same as LocalEmu / Moto / LocalStack / real AWS, hardened how
- [Use case: OpenTofu → Expo + IAM](./use-cases/opentofu-expo-iam) — hero path
- [Vision](./vision) — what “fully working” means
- [Completeness](./completeness) — Working vs Partial vs stub
- [Console tour](./console-tour) — more screenshots of shipped surfaces
- Deep agent/dev notes stay in the repo under [`docs/`](https://github.com/kgz/stackwrangler/tree/main/docs)

### Docs site locally

```bash
cd docs-site
pnpm install
pnpm dev      # http://127.0.0.1:5173/
```

Hosted target (after the repo is public + Pages enabled): https://kgz.github.io/stackwrangler/
