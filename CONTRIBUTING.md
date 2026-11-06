# Contributing

Thanks for interest in stackwrangler.

**To run the stack as a user**, use the Docker image path — no clone: [docs/docker-install.md](docs/docker-install.md) (also the root README). This file is for people changing the product.

## Prerequisites

- Docker Engine on Linux (Compose v2). Windows users: run Linux via WSL with Docker Desktop WSL integration or an engine inside WSL.
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- Node / yarn (console Vite) when working on `console/`

Optional for some smokes: `psql`, `mysql`, `sshpass`.

## Local stack (checkout)

```bash
cp .env.example .env   # first time; `up` also does this
./bin/stackwrangler up
./bin/stackwrangler console   # Vite → http://127.0.0.1:3000
aws --profile local s3 ls
```

SeaweedFS S3 is `:8333`; LocalEmu (IAM, Lambda, CFN, …) is `:4566`. Public image users get a baked nginx console instead of Vite — [docs/docker-install.md](docs/docker-install.md).

```bash
./bin/stackwrangler down                 # keep profile
./bin/stackwrangler down --remove-profile
```

If profile `local` exists and isn’t stackwrangler-managed: `./bin/stackwrangler up --force`.

Release images (orchestrator + patched LocalEmu + console): `./bin/build-release-images.sh`.

## Pull requests

1. Branch from `main`: `feature/<short-slug>` (or `feature/<issue>-<short-slug>` when fixing a tracked issue).
2. Keep the change focused; match existing style.
3. Run the smokes or checks that cover your area (see [docs/test-paths.md](docs/test-paths.md) / [docs/smoke-matrix.md](docs/smoke-matrix.md) when relevant).
4. Open a PR against `main`. Link the issue with `Closes #<n>` when applicable.
5. Expect review from CODEOWNERS (`@kgz`).

Do not put secrets, real AWS credentials, or agent attribution (`Co-authored-by` for bots) in commits.

## Agents / maintainers

Board lifecycle, OpenSpec, Open Design, and gap-check rules live in [AGENTS.md](AGENTS.md) — for people (and agents) driving the project board. External contributors do not need that workflow to send a normal PR.

## Security

See [SECURITY.md](SECURITY.md).
