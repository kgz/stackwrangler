## Context

LocalEmu already has EC2 Docker VPC networks, an `elbv2` provider with `listener_router.py`, and Route 53 control plane. Gaps are enforcement (routes/SGs) and real forwarding/DNS from workloads. Patches land under `localemu-patches/` mounted in compose (same pattern as ECS #201).

## Goals / Non-Goals

**Goals:** Smokes that prove private-subnet isolation, peering reachability, SG allow/deny, NLB/ALB forward + health, private zone resolve from associated VPC only.

**Non-Goals:** Full AWS NAT performance, TLS termination fidelity beyond ACM attach, WAF, cross-region, console create UX (#146).

## Decisions

1. **Subnet = Docker network (or netns)** attached at EC2/ECS/Lambda start from subnet id — reuse/extend `localemu.services.ec2.docker.vpc_network`.
2. **Route enforcement** via iptables/CNI in the workload netns (or gateway container per subnet) — prefer one subnet gateway sidecar if per-container iptables proves fragile under compose.
3. **ELBv2 data plane** — LocalEmu `listener_router` (or HAProxy/envoy sidecar) binds LB DNS; targets by instance/ip + port; health checks update moto target health.
4. **SG enforcement** — filter at target accept path (and egress where cheap); NLB preserves client IP so target SG sees caller/proxy CIDR.
5. **Private DNS** — CoreDNS/dnsmasq sidecar or Docker `--dns` pointing at LocalEmu resolver fed by private zones + VPC association.
6. **Ship order** — #204 routes → #205 SG → #203 ELB (needs targets reachable) → #206 DNS (needs LB DNS names). Parallel patches OK if interfaces agreed.

## Risks / Trade-offs

- Compose + docker.sock nested networking may break hairpin (#181) — document Debt if smoke needs host-gateway hacks.
- Full route/SG matrix is large — first slices cover acceptance smokes only; widen later.

## Migration

Operators: `./bin/awsbox up --force` after pull to remount patches. No fixture format change until #216.
