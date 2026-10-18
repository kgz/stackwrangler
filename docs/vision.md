# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. The console and the CLI talk to that same account.

Learning target: use real tools (`aws …`) against something that *feels* like AWS — without a real AWS bill.

End state: a **docker stack you run once** that auto-configures endpoints and API keys (profile `local`).

## Milestones (GitHub)

**v1** = the most-used Serverless learning path (parallel tracks — finish S3 first, then stack the rest):

| Milestone | Scope |
|-----------|--------|
| [v1 — S3 general purpose](https://github.com/kgz/awsl/milestone/1) | SeaweedFS + profile `local` + CLI + AWS-look **General purpose buckets** |
| [v1 — IAM](https://github.com/kgz/awsl/milestone/3) | Roles/policies; `AccessDenied` as a learning surface |
| [v1 — Lambda](https://github.com/kgz/awsl/milestone/4) | Functions, invoke, console, local runtime |
| [v1 — API Gateway](https://github.com/kgz/awsl/milestone/5) | HTTP/REST → local Lambdas |
| [v1 — CloudWatch Logs](https://github.com/kgz/awsl/milestone/6) | Log groups + Lambda log tail |

**v2+** = deeper / less common:

| Milestone | Scope |
|-----------|--------|
| [v2 — S3 advanced](https://github.com/kgz/awsl/milestone/2) | Access Points, Storage Lens, Batch Ops, Directory/Table/Vector if backend allows |

Suggested build order inside v1: **S3 → IAM → Lambda → Logs → API Gateway** (each unblocks the next).

### v1 S3 sidebar

| Sidebar item | v1 S3 |
|--------------|--------|
| General purpose buckets | **Live** |
| Directory / Table / Vector, Files, Access*, Storage* | Nav chrome → empty / later (**v2**) |
| Object **preview** in UI (view contents) | Later backlog — not v1 |

```bash
./bin/awsbox up
./bin/awsbox console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

**Why SeaweedFS (for S3):** MinIO images are gone. Backend is swappable; console is only a client. IAM uses LocalEmu (`IAM_ENFORCEMENT=1`) on `:4566`; Lambda/APIGW can reuse that emulator.

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Milestones | GitHub milestones |
| Delivery design | OpenSpec changes |
| Console mocks | `design/awsbox-console/` |
| Product entry | `./bin/awsbox` |
