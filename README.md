# awsl / awsbox

One local AWS account. Real APIs. Console on localhost. Learn AWS without a bill.

**M1:** MinIO (S3) in Docker → auto profile `local` → full `aws s3` → AWS-look console. No IAM yet.

See [docs/vision.md](docs/vision.md).

## Board

[Project #8](https://github.com/users/kgz/projects/8/views/1)

```bash
./bin/board-status.sh in-progress <n>
./bin/board-audit.sh          # drift vs bin/board-tracker.tsv
./bin/setup-github-board.sh   # add open issues → Backlog
```

## OpenSpec

```bash
/opsx-propose   # new change
/opsx-apply     # implement tasks.md
/opsx-explore   # think first
```

## Open Design

Console mocks: `design/awsbox-console/` (OD project `awsbox-console`, folder-imported).

```bash
./bin/od-design-run.sh --issue <n> "Design …"
```
