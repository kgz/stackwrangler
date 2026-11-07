# vs Moto

**Moto** is a mock-first AWS API (in-process `@mock_aws` or `moto_server`). Fast for unit/CI tests. **stackwrangler** is an account product on LocalEmu — same *API shape* for many calls, different **fidelity bar**.

Moto also lives **inside** LocalEmu for many service backends. We do not “win by avoiding moto”; we assemble, patch, enforce, and parity-check the account.

## Choose Moto if

- Wall-clock and RAM matter more than network / SG fidelity (unit tests, CI)
- You use `@mock_aws` / moto_server for app logic without real packet filtering
- You do not need a shared local console + multi-tool IaC account

## Choose stackwrangler if

- You need **IAM that denies** (not Moto’s mock-friendly allow path) so OpenTofu catches **AccessDenied** before real AWS
- You need CLI + console + IaC on one local account, including VPC / SG / messaging depth

## Comparison

| | Moto (standalone) | stackwrangler |
|--|-------------------|---------------|
| Philosophy | Mock-first, in-memory | Hardened, opinionated assembly on LocalEmu |
| Best at | Fast tests / CI | End-to-end account staging |
| IAM | Improving; weaker for org-path “fails like AWS” | `IAM_ENFORCEMENT=1` + deny / resource-policy smokes |
| Lambda | Can Docker-invoke (not “Python-only”) | Docker runtime via LocalEmu; same account as IAM/VPC |
| EC2 / SG | API state — rules do **not** filter real packets | Docker-backed instances + VPC/SG patches |
| Console | Tracker-style dashboard | Grey-rose AWS-shaped console |

## Myths

- **“Moto never runs Lambda in containers”** — Moto can Docker-invoke. Gap is fidelity / VPC / IAM depth, not “no containers.”
- **“stackwrangler replaces moto”** — moto remains inside LocalEmu.
- **“Movie set vs replica”** — fine if scoped to EC2/network/org-path authz; do not claim absolute.

## Spine

Same AWS API *shape* as Moto for many operations — different bar: **not default-allow**, enforce IAM, harden networking, parity-check deny paths.

Next: [Compare index](./) · [vs LocalEmu](./vs-localemu) · [IAM deny](../interactions/iam-deny)
