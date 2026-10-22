## 1. VPC routing (#204)

- [ ] 1.1 Extend subnet→Docker network attach for EC2 / ECS awsvpc / VPC Lambda
- [ ] 1.2 Enforce route tables (local, peering, IGW, NAT, gateway endpoints)
- [ ] 1.3 Smoke: private no-default-route isolation; peering both ways; NAT egress
- [ ] 1.4 Docs + README + matrix/test-paths; PR → `beta/full-flow-v1`

## 2. Security groups (#205)

- [ ] 2.1 Enforce SG ingress/egress on workload paths (CIDR + SG ref)
- [ ] 2.2 NLB client-IP passthrough vs target SG
- [ ] 2.3 Smoke allow/deny + NLB path; docs; PR → beta

## 3. ELBv2 data plane (#203)

- [ ] 3.1 NLB TCP forward + health → `describe-target-health`
- [ ] 3.2 ALB default + host/path rules
- [ ] 3.3 LB DNS resolvable; smokes; docs; PR → beta

## 4. Private DNS (#206)

- [ ] 4.1 Resolver for workloads (Docker DNS / forwarder)
- [ ] 4.2 Private zone VPC association + CNAME/alias to ELB
- [ ] 4.3 Smoke associated vs unassociated; docs; PR → beta

## 5. Gap check

- [ ] 5.1 `./bin/gap-check.sh` per ticket; Debt for Partial (console #146 already)
