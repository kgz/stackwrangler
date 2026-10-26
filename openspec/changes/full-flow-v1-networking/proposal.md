## Why

Real accounts fail on routes, security groups, load balancers, and private DNS. Locally those mistakes are invisible today, so stacks that need an NLB → proxy → internal NLB path (or private-subnet-without-default-route behaviour) cannot be rehearsed. Milestone `full-flow-v1` tickets #203–#206 close that gap.

## What Changes

- ELBv2 **data plane**: NLB/ALB listeners forward to target groups; health checks drive `describe-target-health`; LB DNS resolvable
- VPC **routing fidelity**: per-subnet attach + enforced route tables (local, peering, IGW, NAT, gateway endpoints)
- **Security group** ingress/egress enforcement between workloads (and NLB client-IP passthrough)
- Route 53 **private hosted zones** resolvable from associated VPC workloads
- Smokes + README/matrix/test-paths updates for each surface

## Capabilities

### New Capabilities
- `elbv2-dataplane`: NLB/ALB forwarding, target groups, health checks (#203)
- `vpc-routing`: subnet networks + route table / peering / IGW / NAT / endpoint enforcement (#204)
- `sg-enforcement`: SG rules between EC2/ECS/Lambda/RDS/LB targets (#205)
- `r53-private-zones`: private zone resolution from associated VPCs (#206)

### Modified Capabilities

## Impact

- LocalEmu `elbv2`, `ec2` (docker VPC), `route53` / resolver; likely `localemu-patches/` mounts + `SERVICES` / compose
- Depends on Docker networking; ECS awsvpc + EC2 + VPC Lambda attach paths
- Console depth remains Debt [#146](https://github.com/kgz/awsl/issues/146) unless separately scoped
