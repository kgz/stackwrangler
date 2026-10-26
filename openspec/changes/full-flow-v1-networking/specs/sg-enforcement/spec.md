## ADDED Requirements

### Requirement: Security group rules filter workload traffic
Ingress and egress rules (CIDR, prefix list, referenced security group, protocol/port) SHALL allow or refuse connections between EC2, ECS, VPC Lambda, RDS, and load balancer targets as in AWS. Explicit deny/missing allow SHALL refuse the connection.

#### Scenario: SG-referenced allow
- **WHEN** a target allows TCP port X only from security group A
- **THEN** a caller in SG A connects and a caller in SG B is refused

#### Scenario: NLB with target SG on proxy CIDR
- **WHEN** traffic arrives through an NLB and the target SG allows the proxy subnet CIDR
- **THEN** NLB-path traffic succeeds and a direct connection from elsewhere fails
