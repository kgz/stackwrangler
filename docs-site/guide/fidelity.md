# Fidelity

Companion to data-plane + authz in [Vision](./vision). Happy smokes prove bytes move. **Fidelity** is the awkward path: settings and topology that bite on real AWS and should show up locally — or be labelled Debt.

This page is the public summary. Working notes: [`docs/fidelity.md`](https://github.com/kgz/stackwrangler/blob/main/docs/fidelity.md).

## Intent

Match AWS closely enough that weird real-world failures appear on the laptop:

- Security group / route table edge cases  
- Same-host / hairpin traffic (e.g. two ECS tasks on one Docker host via VIP/NAT)  
- Load balancer client-IP / health-check quirks  
- IAM condition keys and resource policies that only bite under real principals  
- Retention / TTL / encryption defaults that differ from “what the docs imply”

v1 may still use bridges and sidecars. Fidelity tickets track when the bridge **lies**.

## How we work it

1. Hit it on real AWS → file `Debt: fidelity: …` with expected vs local + minimal repro  
2. Do not block org-path data/authz tickets on every topology edge  
3. Prefer local-vs-real parity scripts once a repro exists  
4. Keep [Completeness](./completeness) honest — Partial / Sidecar / Stub stay labelled  

## Matrix (seed)

| Gap | Why it matters | Status |
|-----|----------------|--------|
| Private subnet routes (no default, peering, NAT, GW endpoints) | Workload cannot reach public host / S3 until a route says so | Covered · `vpc-routing-smoke` / `vpc-egress-smoke` |
| VPC Lambda security groups | Function traffic follows its groups (netns iptables) | Covered · `sg-enforcement-smoke` |
| Dual S3 brains | Wrong endpoint “succeeds” | Documented · [Dual S3](./interactions/dual-s3) |
| NLB preserves client IP for target SG | Target must see caller, not balancer | Debt · track in networking |
| ECS same-host hairpin via VIP/NAT | Works across AZs, fails same host on real AWS | Debt · networking fidelity |
| ECS task-role via 169.254 under compose | In-container SDK credential path | Tracked · see repo issues |

Add rows as Debts land; keep the list short. Deep table lives in-repo.

## Relation to IAM

Fidelity includes networking knobs, but the **first** false-green we refuse is **default-allow IAM**. Enforcement is on by product default — [Architecture](./architecture), [Compare](./compare/).

## Related

- [Architecture](./architecture) — assembly layers  
- [Completeness](./completeness) — Working / Partial map  
- [Interactions](./interactions/) — proven edges  

Not affiliated with Amazon Web Services.
