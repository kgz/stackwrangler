# vs LocalStack

**LocalStack** (current product) is a commercial emulator with tiers. **LocalEmu** is the free open lineage we build on. **stackwrangler** productizes LocalEmu into a hardened local account.

We are not LocalStack. We chose LocalEmu because we need enforcement and open dataplane depth without a paid emulator tier for core authz — then we add patches, console, and honesty about depth.

## Choose LocalStack if

- Your org is already licensed / standardized on it
- You need their managed Cloud Pods, support, or Pro services we do not cover

## Choose stackwrangler if

- You want free local IAM that **does not default-allow** (`IAM_ENFORCEMENT=1`) without a paid emulator tier
- You want Working / Partial / Stub labelled honestly, plus console + inspectable patches
- You care about parity on deny paths, not catalogue width alone

## The LocalStack lesson (why we refuse false green)

Orgs often tried LocalStack for full local repro and got a silent green:

- Community IAM that did not enforce → missing policies still “succeeded”
- Control plane ≠ data plane → resources exist; traffic/authz does not
- Pro-gated / uneven depth → catalogue looks wide
- Endpoint sprawl → CLI, console, and Lambda on different brains

stackwrangler stance: never market `create-*` as shipped; prefer `IAM_ENFORCEMENT=1` and real sidecars when the emulator cannot move bytes. See [Why](../why) and [Vision](../vision).

## Spine

Same job as a LocalStack-shaped `:4566` emulator — **not default-allow**, hardened with patches/console, deny paths checked against real AWS.

Lineage and notices: [THIRD_PARTY.md](https://github.com/kgz/stackwrangler/blob/main/THIRD_PARTY.md).

Next: [Compare index](./) · [vs LocalEmu](./vs-localemu) · [Completeness](../completeness)
