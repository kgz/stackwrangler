# Slice: egress (#230)

VPC Lambda in a private subnet with no default route. Asserts:

- public host times out
- S3 via a gateway endpoint (prefix-list DNAT) succeeds
- peer VPC CIDR succeeds
- adding an IGW/NAT route restores public egress

Run: `./bin/vpc-egress-smoke.sh`
