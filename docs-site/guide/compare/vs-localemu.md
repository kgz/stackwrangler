# vs LocalEmu

**LocalEmu** is the free AWS API emulator. **stackwrangler** runs on it — a hardened, opinionated assembly (patches, sidecars, console, profile, smokes), not a second emulator. Lead difference: **we default to IAM enforcement**, not default-allow.

## Choose stackwrangler if

- You refuse **default-allow** IAM — want `IAM_ENFORCEMENT=1` on, with deny smokes / parity
- You want CLI + grey-rose **console** + IaC on the **same** local account
- You need dataplane depth LocalEmu alone may not ship for your path (VPC/SG behaviour, Transfer SFTP, connectors, Docker RDS, ECR registry — see `localemu-patches/` + sidecars)
- You prefer honest Working / Partial / Stub over catalogue theatre
- You want `up` → profile `local` with less glue

## Choose pure LocalEmu if

- You only need API shape and no console
- You will turn on enforcement yourself (or accept default-allow risk)
- You want minimal opinion and your own compose / networking
- You do not need our Transfer / VPC / SG / sidecar depth

## What we add

| Layer | LocalEmu alone | stackwrangler |
|-------|----------------|---------------|
| Engine | LocalEmu `:4566` | Same (pinned image + mounts) |
| IAM | You must enable enforcement | **`IAM_ENFORCEMENT=1` on** — not default-allow |
| Other defaults | You configure | Docker RDS, SQS retention, … |
| Depth gaps | Upstream behaviour | `localemu-patches/` + sidecars (SeaweedFS, ECR registry, …) |
| Console | None | Grey-rose console on `:3000` |
| Proof | Your tests | Smokes + documented status matrix |

## Myths

- **“Just a wrapper / same validation limits”** — false. Defaults, patches, and parity smokes change fidelity.
- **“Loopback means prefer LocalEmu for Expo”** — host ports publish as `127.0.0.1` on purpose (laptop safety). Phone → laptop is a host-reachability problem either way; simulators often need no bind change (`127.0.0.1` / Android `10.0.2.2`). See the [OpenTofu → Expo use case](../use-cases/opentofu-expo-iam).
- **Dual S3** — console buckets use SeaweedFS (`:8333`); IaC / Lambda / events use LocalEmu S3 (`:4566`). Intentional for now — [Concepts](../concepts), [Dual S3](../interactions/dual-s3).

## Spine

Same engine class as LocalEmu — but **not default-allow**: enforcement on by product default, then patches / console / parity so a green `apply` is not false confidence.

Next: [Compare index](./) · [vs Moto](./vs-moto) · [Why](../why)
