# awsbox — north star

Living product intent. Not a ticket; update when the destination shifts.

## Feel

**One local AWS account** that speaks the real AWS API. The console and the CLI talk to that same account.

Learning target: use real tools (`aws …`) against something that *feels* like AWS — without a real AWS bill.

End state: a **docker stack you run once** that auto-configures endpoints and API keys (profile `local`).

## Milestones (GitHub)

| Milestone | Scope |
|-----------|--------|
| [v1 — S3 general purpose](https://github.com/kgz/awsl/milestone/1) | SeaweedFS + `local` profile + CLI + AWS-look console for **General purpose buckets** |
| [v2 — S3 access & management](https://github.com/kgz/awsl/milestone/2) | Access Points, grants, Storage Lens / Batch Ops; specialty bucket types if backend allows |
| [v3 — IAM](https://github.com/kgz/awsl/milestone/3) | Policies / AccessDenied as a learning surface |
| [v4 — Lambda](https://github.com/kgz/awsl/milestone/4) | Functions, invoke, logs |
| [v5 — API Gateway](https://github.com/kgz/awsl/milestone/5) | HTTP/REST → local Lambdas |

### v1 S3 sidebar — what is “in”?

Real AWS S3 nav has many sections. **We do not implement all of them in v1.**

| Sidebar item | v1 |
|--------------|----|
| General purpose buckets | **Live** (ListBuckets / Create / objects) |
| Directory / Table / Vector buckets | Nav chrome only → empty / “not on local stack” |
| File systems | Chrome only |
| Access Points / Grants / Access Analyzer | Chrome only → **v2** |
| Storage Lens / Batch Operations | Chrome only → **v2** |
| Account settings / Marketplace | Chrome only |

```bash
./bin/awsbox up
./bin/awsbox console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

**Why SeaweedFS:** MinIO community images are gone. Backend is swappable; console is only a client.

## What goes where

| Thing | Home |
|-------|------|
| This north star | `docs/vision.md` |
| Tickets | GitHub Project #8 |
| Milestones | GitHub milestones v1–v5 |
| Delivery design | OpenSpec changes |
| Console mocks | `design/awsbox-console/` |
| Product entry | `./bin/awsbox` |
