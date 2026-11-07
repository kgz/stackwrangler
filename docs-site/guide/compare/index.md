# Compare

**Biggest gap in most local AWS stacks: permissions default-allow.** Missing or wrong IAM still “succeeds.” You only learn on real AWS.

stackwrangler turns that around: **`IAM_ENFORCEMENT=1` by default** — workload principals and resource policies **AccessDenied** when the policy is wrong, with smokes / real-AWS parity on deny paths. Same local AWS-shaped account as the free emulator class — then **hardened** (patches, console, sidecars) so a green `apply` is not false confidence.

**Positioning:** an **IaC verification sandbox** for OpenTofu / Terraform (and CDK / SAM / Serverless) plus console / mobile clients — **not** a generic LocalStack clone.

| Same as the emulator class | Hardened how |
|----------------------------|----------------|
| AWS APIs on localhost | **Authz that denies** (`IAM_ENFORCEMENT=1`) — not default-allow |
| IaC / CLI / SDK | Patches for gaps that matter (VPC/SG, Transfer, resource policies, …) |
| “It runs locally” | Smokes + real-AWS parity where we claim it (deny paths first, not only `create-*`) |
| Service catalogue | Honest Working / Partial / Stub — see [Completeness](../completeness) |

LocalEmu is the emulator engine. **stackwrangler** is the account product (compose, profile, console, `localemu-patches/`, sidecars, smokes).

## Pages

| Page | When someone asks… |
|------|---------------------|
| [vs LocalEmu](./vs-localemu) | Raw engine vs assembly |
| [vs Moto](./vs-moto) | Fast mocks / CI vs account fidelity |
| [vs LocalStack](./vs-localstack) | Paid emulator / false-green history |
| [vs real AWS](./vs-real-aws) | “Just use a sandbox account” |
| [vs SAM Local / serverless-offline](./vs-sam-local) | Lambda-only local runners |
| [vs other free emulators](./vs-other-emulators) | fakecloud, Floci, and similar forks |

Hero path: [Use case — OpenTofu → Expo + IAM](../use-cases/opentofu-expo-iam).

How the assembly works: [Architecture](../architecture) · awkward paths: [Fidelity](../fidelity).

Not affiliated with Amazon Web Services.
