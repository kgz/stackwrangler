# vs other free emulators

After LocalStack Community went away, several free `:4566`-class projects showed up (**Floci**, **fakecloud**, **MiniStack**, raw **LocalEmu**, …). Names change; the product question does not.

## Wire conformance ≠ runnable stack

Some tools advertise **100% Smithy / protocol conformance** (every operation answers with the right shapes and error codes). That is **control-plane wire accuracy** — great for SDK and IaC *shape* tests.

It does **not** mean containers boot, SNS delivers, or IAM denies when a role is wrong. stackwrangler’s bar is the other one: create → configure → **traffic or data moves** → **AccessDenied** when the principal hop is wrong. See [Why](../why) · [Completeness](../completeness).

## fakecloud

**fakecloud** is a strong headless emulator: broad Smithy coverage, optional strict IAM (Allow/Deny/boundaries/trust/SCPs), AGPL-3.0.

| | **fakecloud** | **stackwrangler** |
|--|---------------|-------------------|
| License | AGPL-3.0 | MIT |
| IAM | Opt-in strict mode | **`IAM_ENFORCEMENT=1` on by default** |
| Shape | Headless binary / API surface | Local account: console, profile `local`, call log (`/_awsl/calls`) |
| Depth pitch | Catalogue + wire conformance | Org-path + sidecars + deny-path smokes; honest Partial/Stub |

Use fakecloud when you want a thin conformance harness or AGPL is fine. Use stackwrangler when you need a **runnable** multi-service path with deny-by-default IAM and a console humans/agents can read.

## Floci / MiniStack

Often **permissive by default** — missing workload policies can still “succeed.” Some Docker-backed compute exists; false-green IAM remains the gap.

| | **Floci / MiniStack-class** | **stackwrangler** |
|--|-----------------------------|-------------------|
| IAM default | Permissive / DIY | Deny-by-default (`IAM_ENFORCEMENT=1`) |
| Product | Emulator / happy-path containers | Hardened assembly + call log + Completeness |

## What stackwrangler adds on LocalEmu

| Emulator alone | stackwrangler |
|----------------|---------------|
| You enable enforcement (or accept default-allow) | Enforcement on by product default |
| Catalogue as marketed | Working / Partial / Stub — we do not market `create-*` as shipped |
| DIY console / sidecars | Console on `:3000` + SeaweedFS / ECR / Transfer where needed |
| Green `apply` hope | Smokes + real-AWS parity where we claim it |

**LocalEmu** is the engine. **stackwrangler** is the account product. Swap the engine if needed — the contract is behaviour, not the logo.

## Choose a raw free emulator if

- You want the thinnest process and will own compose, networking, and fidelity
- Wire/Smithy conformance or catalogue width is the main goal
- You accept permissive / opt-in IAM

## Choose stackwrangler if

- Agents or humans must run **real hops** (containers, messaging, mobile) with **AccessDenied** when IAM is wrong
- You want one profile + console + call log for the team
- MIT matters for legal review

Named deep-dives: [vs LocalEmu](./vs-localemu) · [vs LocalStack](./vs-localstack) · [vs AWS Emulator](./vs-aws-emulator).

Next: [Compare index](./) · [Why](../why)
