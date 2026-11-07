# Fidelity — settings & topology (planning)

Not v1 width. Companion to data-plane + authz in [vision.md](vision.md).

## Intent

awsbox should eventually match AWS closely enough that **weird real-world failures** show up locally:

- Security group / NACL / route table edge cases  
- **Same-host / hairpin** traffic (e.g. two ECS tasks on one Docker host talking via a VIP/NAT/proxy — fails without correct hairpin / IP retention / conntrack behaviour)  
- Load balancer stickiness, idle timeouts, health-check quirks  
- IAM condition keys, session policies, resource policies that only bite under load  
- Retention, TTL, encryption defaults that differ from “what the docs imply”

Happy smokes prove bytes move. **Fidelity smokes** prove the *awkward* path matches AWS (or we document an honest gap + Debt).

## How we work this without boiling the ocean

1. **When you hit it in real AWS** → file `Debt: fidelity: …` with: expected AWS behaviour, local outcome, minimal repro.  
2. **Board** — backlog; do not block org-path data/authz tickets.  
3. **Parity scripts** (local vs real) are the preferred proof once a repro exists — same shape as CFN/IAM parity.  
4. **v1** may still use bridges/sidecars; fidelity tickets track when the bridge *lies*.

## Seed examples

| Gap | Why it matters | Status |
|-----|----------------|--------|
| ECS task↔task on same host via service VIP / NAT hairpin | Classic “works across AZs, fails same host” | Covered · matches AWS fail under `AWSBOX-ELBV2` DNAT · [ecs-hairpin.md](ecs-hairpin.md) · `./smokes/networking/ecs-hairpin-smoke.sh` · [#181](https://github.com/kgz/awsl/issues/181) |
| Private subnet route table (no default, peering, NAT, GW endpoints) | Workload cannot reach a public host / S3 until a route says so | Covered · `./smokes/networking/vpc-routing-smoke.sh` · `./smokes/networking/vpc-egress-smoke.sh` |
| Dual S3 brains | Wrong endpoint “succeeds” | Documented split · unify [#162](https://github.com/kgz/awsl/issues/162) |
| ECS task-role via 169.254 DNAT under compose | In-container SDK path (awsvpc + bridge; sidecar when image lacks iptables) | Covered · `./smokes/compute/ecs-authz-smoke.sh` · `./smokes/compute/ecs-bridge-no-iptables-authz-smoke.sh` · [#154](https://github.com/kgz/stackwrangler/issues/154) · [#254](https://github.com/kgz/stackwrangler/issues/254) |
| NLB preserves client IP for the target security group | Target SG must see the caller, not the balancer | [#236](https://github.com/kgz/awsl/issues/236) |
| VPC Lambda security groups | Function traffic follows its groups via netns sidecar iptables | covered · `./smokes/networking/sg-enforcement-smoke.sh` · [#237](https://github.com/kgz/awsl/issues/237) |

Add rows as Debts land; keep this file short.
