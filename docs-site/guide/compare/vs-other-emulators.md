# vs other free emulators

After LocalStack’s Community edition was archived, several free LocalStack-shaped projects appeared (for example **fakecloud**, **Floci**, and other `:4566` forks). Names change; the product question does not.

We do not maintain a separate page per fork until one dominates mindshare. The contrast is the same for all of them.

## Same engine class

Point SDKs / CLI / IaC at a local AWS API endpoint. Services answer. That is the free emulator job.

## What stackwrangler adds

| Emulator alone | stackwrangler |
|----------------|---------------|
| Often **default-allow** IAM | **`IAM_ENFORCEMENT=1`** — AccessDenied when wrong |
| Catalogue as marketed | Honest Working / Partial / Stub |
| Your own glue for console / sidecars | Grey-rose console + SeaweedFS / ECR / Transfer wiring |
| Hope the green `apply` is real | Smokes + real-AWS parity where we claim it |
| DIY patches | Inspectable `localemu-patches/` for org-path gaps |

Our engine today is **LocalEmu**. The assembly is the product. If we swapped engines, the contract would still be account behaviour — see [Vision](../vision).

## Choose a raw free emulator if

- You want the thinnest possible process and will own compose, networking, and fidelity yourself
- You do not need our console or org-path patches

## Choose stackwrangler if

- You want the same job **hardened and opinionated**, with proof on deny / dataplane paths
- You want one profile and console for the team

## Spine

Same free-emulator job — **not default-allow**, then harden and parity-check.

Named deep-dives: [vs LocalEmu](./vs-localemu) · [vs LocalStack](./vs-localstack).

Next: [Compare index](./) · [Why](../why)
