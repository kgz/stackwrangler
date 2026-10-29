# stackwrangler

**Not affiliated with Amazon Web Services.** Independent open-source tooling to develop and test AWS-shaped stacks locally, then deploy to real AWS. Not an AWS product and not a hosted substitute for AWS.

One **local AWS-shaped account** — real APIs, a grey-rose console on localhost, and IaC against profile `local`. Learn and stage without a cloud bill. Authz that **denies** when the policy is wrong — not a silent green.

North star: [docs/vision.md](docs/vision.md) · Docs: [docs-site/](docs-site/) → [kgz.github.io/stackwrangler](https://kgz.github.io/stackwrangler/) · Status: [docs/status.md](docs/status.md) · [LICENSE](LICENSE) (MIT) · [THIRD_PARTY.md](THIRD_PARTY.md)

## Console

Live local console (grey rose chrome) — same account as CLI and IaC.

![S3 buckets in the stackwrangler console](docs/assets/console/home-s3-buckets.png)

![Lambda functions](docs/assets/console/lambda-functions.png)

![CloudFormation stacks](docs/assets/console/cloudformation-stacks.png)

## Features

- **One local account** — CLI (`aws --profile local`), console (`./bin/stackwrangler console`), and Terraform / CDK / SAM / Serverless hit the same endpoints
- **Fully working bar** — create → configure → traffic or data moves → you can see it. Control-plane stubs stay labelled stubs (no catalogue theatre)
- **Authz that denies** — LocalEmu with `IAM_ENFORCEMENT=1`; workload principals and resource policies fail like AWS when the policy is wrong
- **Honest depth** — Working / Partial / Sidecar / Backlog are first-class; see [docs/status.md](docs/status.md)
- **Local → real AWS** — stage here, then point the same tooling at a real account

Built on **LocalEmu** (not LocalStack Community — we need IAM enforcement) plus sidecars: **SeaweedFS** (console buckets), **distribution/registry** (ECR-shaped push/pull), **atmoz/sftp** (Transfer dataplane). Console buckets UI uses SeaweedFS; IaC / Lambda / S3 events use **LocalEmu S3** ([docs/s3-backends.md](docs/s3-backends.md)).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (Compose v2)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- Optional: `psql`, `mysql`, `sshpass` for RDS / Transfer dataplane smokes

WSL: ports bind to `127.0.0.1` — use Docker Desktop with WSL integration (or an engine in WSL).

## Quick start

```bash
git clone https://github.com/kgz/stackwrangler.git
cd stackwrangler
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

`./bin/stackwrangler up` copies `.env.example` → `.env` on first run (`STACKWRANGLER_*` vars). Tear down with `./bin/stackwrangler down` (add `--remove-profile` to drop profile `local`).

| What | Where |
|------|--------|
| S3 (console buckets) | `http://127.0.0.1:8333` SeaweedFS |
| LocalEmu (IAM, Lambda, CFN, Transfer, RDS, …) | `http://127.0.0.1:4566` |
| Transfer SFTP (native) | `127.0.0.1:2222` ([docs/transfer.md](docs/transfer.md)) |
| Console | `http://127.0.0.1:3000` |
| Profile | `local` |

If profile `local` exists and isn’t stackwrangler-managed: `./bin/stackwrangler up --force`.

Coming from older checkouts named `awsbox`: `./bin/awsbox` still works as a shim that execs `stackwrangler` (and prints a rename notice). Prefer `./bin/stackwrangler` and `STACKWRANGLER_*` env vars.

## Documentation

- [Vision](docs/vision.md) — north star and fidelity bar
- [Service status](docs/status.md) — Working / Partial matrix
- [Contributing](CONTRIBUTING.md)

A VitePress docs site and GitHub Pages URL land with [#403](https://github.com/kgz/stackwrangler/issues/403) / [#428](https://github.com/kgz/stackwrangler/issues/428) — not linked here until they exist.

## License

[MIT](LICENSE) · third-party notices: [THIRD_PARTY.md](THIRD_PARTY.md)
