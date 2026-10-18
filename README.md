# awsl / awsbox

One local AWS account. Real APIs. Console on localhost. Learn AWS without a bill.

**M1:** SeaweedFS (S3 API) in Docker → auto profile `local` → full `aws s3` → AWS-look console. No IAM theatre yet.

Backend is swappable later (console is only a client). See [docs/vision.md](docs/vision.md).

## Quick start (M1 S3)

Needs Docker + [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

```bash
cp .env.example .env   # first time only; awsbox up also does this
./bin/awsbox up
./bin/awsbox console   # http://127.0.0.1:3000 — AWS-look S3 UI
# other terminal:
aws --profile local s3 mb s3://awsbox-smoke
aws --profile local s3 ls
./bin/awsbox down                 # keep profile
./bin/awsbox down --remove-profile
```

| What | Where |
|------|--------|
| S3 API | `http://127.0.0.1:8333` (SeaweedFS) |
| Console | `http://127.0.0.1:3000` (`./bin/awsbox console`) |
| AWS profile | `local` (keys from `.env`) |

`./bin/awsbox status` — container + live check.

If profile `local` already exists and isn’t awsbox-managed: `./bin/awsbox up --force`.

### WSL / Docker

Ports bind to `127.0.0.1` on the WSL side. Use Docker Desktop with WSL integration (or engine in WSL).

## Board

[Project #8](https://github.com/users/kgz/projects/8/views/1)

```bash
./bin/board-status.sh in-progress <n>
./bin/board-audit.sh
./bin/setup-github-board.sh
```

## OpenSpec

```bash
/opsx-propose
/opsx-apply
/opsx-explore
```

## Open Design

Console mocks: `design/awsbox-console/` (AWS S3 dark ref: `design/awsbox-console/refs/`).

```bash
./bin/od-design-run.sh --issue <n> "Design …"
```
