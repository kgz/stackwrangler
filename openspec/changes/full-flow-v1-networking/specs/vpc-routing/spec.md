## ADDED Requirements

### Requirement: Workloads attach to subnet networks
EC2, ECS (awsvpc and container-instance bridge where applicable), and VPC Lambda SHALL attach to a Docker network (or equivalent) derived from their subnet so routing can be enforced per subnet.

#### Scenario: Private subnet without default route
- **WHEN** a workload runs in a private subnet whose route table has no `0.0.0.0/0` route
- **THEN** it cannot reach a public internet host directly

### Requirement: Peering and NAT routes
The system SHALL honour VPC peering routes (including non-RFC1918 CIDRs when configured) and NAT gateway default routes for egress.

#### Scenario: Peering both ways
- **WHEN** two VPCs are peered with routes on both sides
- **THEN** workloads can reach each other; removing a route on one side breaks that direction

#### Scenario: NAT restores egress
- **WHEN** a private subnet gains a `0.0.0.0/0` route to a NAT gateway
- **THEN** the workload can reach a public HTTP endpoint via NAT
