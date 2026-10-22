## ADDED Requirements

### Requirement: Private hosted zones resolve inside associated VPCs
Workloads in a VPC associated with a private hosted zone SHALL resolve A/AAAA/CNAME and alias records for that zone (including aliases to ELB). Workloads in unassociated VPCs SHALL NOT resolve those private names via the private zone.

#### Scenario: CNAME to internal NLB
- **WHEN** a private zone has a CNAME to an internal NLB DNS name and an ECS task runs in the associated VPC
- **THEN** the name resolves and connects; a task in an unassociated VPC does not use that private answer

#### Scenario: Alias to ALB
- **WHEN** a private zone alias targets an ALB
- **THEN** resolution from an associated VPC returns the ALB addresses
