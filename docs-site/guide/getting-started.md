# Getting Started

Bring up a local AWS-shaped account, open the console, and talk to it with the AWS CLI.

**Not affiliated with Amazon Web Services.** stackwrangler is independent OSS: test locally, then deploy to real AWS.

## Prerequisites

- Docker
- AWS CLI v2
- Node / yarn (for the console; `./bin/stackwrangler console` installs deps on first run)

## 1. Clone and start the stack

```bash
git clone https://github.com/kgz/stackwrangler.git
cd stackwrangler
./bin/stackwrangler up
```

That starts SeaweedFS (S3 for the console and `aws --profile local`), LocalEmu (IAM, Lambda, CFN, … on `:4566`), and related sidecars. It writes AWS profile `local`.

## 2. Open the console

```bash
./bin/stackwrangler console
# → http://127.0.0.1:3000
```

Grey-rose chrome, same account as the CLI. Home opens on **S3 general purpose buckets** (SeaweedFS):

![Console home — S3 buckets](/assets/console/home-s3-buckets.png)

## 3. Use the AWS CLI

```bash
aws --profile local s3 ls
aws --profile local --endpoint-url http://127.0.0.1:4566 lambda list-functions
```

Profile `local` points S3 at SeaweedFS (`:8333`). Most other services use LocalEmu (`:4566`). See [Concepts](./concepts) for the dual-S3 split.

## 4. Next

- [Vision](./vision) — what “fully working” means
- [Completeness](./completeness) — Working vs Partial vs stub
- [Console tour](./console-tour) — more screenshots of shipped surfaces
- Deep agent/dev notes stay in the repo under [`docs/`](https://github.com/kgz/stackwrangler/tree/main/docs)
