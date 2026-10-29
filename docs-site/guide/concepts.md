# Concepts

Short public framing. Deep notes stay in the repo `docs/` tree.

## LocalEmu (not LocalStack Community)

stackwrangler’s emulator process is **LocalEmu** on `http://127.0.0.1:4566`. We need **IAM enforcement** (`IAM_ENFORCEMENT=1`) so wrong workload policies fail locally. LocalStack Community’s weak IAM is exactly the false-green lesson in [Vision](./vision).

stackwrangler is the **product** around that emulator: Compose, profile `local`, console, smokes, examples, and honesty about depth. Swap the emulator if needed — the contract is account behaviour.

## Dual S3

Two S3 APIs on purpose until a later unify:

| Brain | Endpoint | Who uses it |
|-------|----------|-------------|
| **SeaweedFS** | `:8333` | Console general-purpose buckets, `aws --profile local` |
| **LocalEmu S3** | `:4566` | Lambda / CFN / CDK / SAM / Transfer bridge / IAM deny labs |

Do not expect one bucket list to cover both. Smoke: `./bin/s3-dual-endpoint-smoke.sh`. Details: [`docs/s3-backends.md`](https://github.com/kgz/stackwrangler/blob/main/docs/s3-backends.md).

## IAM enforcement intent

- Root / stackwrangler keys admin the box.
- **Workload** roles, resource policies, and trust conditions should deny like AWS.
- Smokes that only happy-path create resources are incomplete; prefer at least one deliberate `AccessDenied`.

## Sidecar vs native

| Pattern | Meaning | Examples |
|---------|---------|----------|
| **Native / in-process** | Emulator implements the API and (ideally) a real data plane | Lambda Docker invoke, many LocalEmu APIs |
| **Sidecar** | Real bytes in another container; API may still be LocalEmu | SeaweedFS S3 UI, atmoz/sftp for Transfer, registry for ECR, Postgres for RDS-shaped |

Sidecars are honest engineering when the emulator cannot deliver the data plane. They are **not** “full AWS.” Label them **Sidecar** / **Partial** on the [Completeness](./completeness) map.

## Local → real AWS

Workflow: build and break on stackwrangler → deploy the same shape to a real account. See [THIRD_PARTY.md](https://github.com/kgz/stackwrangler/blob/main/THIRD_PARTY.md) and the product disclaimer: **not affiliated with Amazon**, not a hosted AWS substitute.
