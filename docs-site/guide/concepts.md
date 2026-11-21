# Concepts

Short public framing. Deep notes stay in the repo `docs/` tree.

## LocalEmu (not LocalStack Community)

stackwrangler’s emulator process is **LocalEmu** on `http://127.0.0.1:4566`. We need **IAM enforcement** (`IAM_ENFORCEMENT=1`) so wrong workload policies fail locally. LocalStack Community’s weak IAM is exactly the false-green lesson in [Vision](./vision).

stackwrangler is the **product** around that emulator: Compose, profile `local`, console, smokes, examples, and honesty about depth. Swap the emulator if needed — the contract is account behaviour. Layers diagram: [Architecture](./architecture).

## Org-path S3 (single brain)

One S3 store for the learner path:

| Brain | Endpoint | Who uses it |
|-------|----------|-------------|
| **LocalEmu S3** | `:4566` | Console buckets, `aws --profile local`, Lambda / CFN / CDK / SAM / Transfer / IAM deny labs |
| **SeaweedFS** | `:8333` | Optional parity smokes only — not the org path |

Put via Transfer / Lambda / CLI must show up where the docs tell you to look (console + `aws --profile local`). Smoke: `./smokes/s3/s3-org-path-brain-smoke.sh`. Details: [`docs/s3-backends.md`](https://github.com/kgz/stackwrangler/blob/main/docs/s3-backends.md).

## IAM enforcement intent

- Root / stackwrangler keys admin the box.
- **Workload** roles, resource policies, and trust conditions should deny like AWS.
- Smokes that only happy-path create resources are incomplete; prefer at least one deliberate `AccessDenied`.

## Sidecar vs native

| Pattern | Meaning | Examples |
|---------|---------|----------|
| **Native / in-process** | Emulator implements the API and (ideally) a real data plane | Lambda Docker invoke, LocalEmu S3 (org path), many LocalEmu APIs |
| **Sidecar** | Real bytes in another container; API may still be LocalEmu | SeaweedFS (optional S3 parity), atmoz/sftp for Transfer, registry for ECR, Postgres for RDS-shaped |

Sidecars are honest engineering when the emulator cannot deliver the data plane. They are **not** “full AWS.” Label them **Sidecar** / **Partial** on the [Completeness](./completeness) map.

## Local → real AWS

Workflow: build and break on stackwrangler → deploy the same shape to a real account. See [THIRD_PARTY.md](https://github.com/kgz/stackwrangler/blob/main/THIRD_PARTY.md) and the product disclaimer: **not affiliated with Amazon**, not a hosted AWS substitute.
