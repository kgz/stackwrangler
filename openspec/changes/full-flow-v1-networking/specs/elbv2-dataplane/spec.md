## ADDED Requirements

### Requirement: NLB forwards TCP to healthy targets
The system SHALL forward TCP connections on an internet-facing Network Load Balancer listener to registered healthy instance or IP targets, and SHALL update `describe-target-health` from health checks. Unhealthy targets SHALL stop receiving new connections.

#### Scenario: Internet-facing NLB to instance targets
- **WHEN** an NLB listens on port 443 with two instance targets and one fails health checks
- **THEN** traffic reaches a healthy target and `describe-target-health` shows the failed target unhealthy

#### Scenario: Internal NLB dynamic ports
- **WHEN** an internal NLB forwards to two targets on different host ports
- **THEN** both healthy targets receive traffic and the LB DNS name resolves from a workload in the VPC

### Requirement: ALB host and path rules
The system SHALL support ALB HTTP listeners with a default action plus host-header and path-pattern rules.

#### Scenario: Host and path routing
- **WHEN** rules send `api.example/v1/*` to TG-A and default to TG-B
- **THEN** matching requests hit TG-A and non-matching hit TG-B

### Requirement: NLB preserves client source IP
For instance targets, the target SHALL observe the original client source IP (not the NLB node IP) so security group rules on the target can allow the caller or proxy subnet.
