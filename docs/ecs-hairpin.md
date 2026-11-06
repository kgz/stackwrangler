# ECS same-host VIP hairpin / NAT IP retention

Fidelity ticket [#181](https://github.com/kgz/awsl/issues/181). Linked from [fidelity.md](fidelity.md).

## AWS shape

Two ECS tasks (awsvpc) on the **same** underlying host often talk through a service VIP — Cloud Map / internal NLB / ALB target group — not the peer ENI IP.

With **NLB client-IP retention** (`preserve_client_ip.enabled=true`, common for IP-mode targets), packets are DNATed toward the target with the caller’s source address. On one host that is a **hairpin**: the VIP lands back on the same host. Without correct hairpin / conntrack behaviour, the connection **fails on the same host** while the identical path **works across hosts/AZs**.

Workarounds in real accounts: ENI-to-ENI (service discovery A records), disable client-IP preservation (SNAT at the balancer), or keep callers and targets on different hosts.

## Local (stackwrangler / LocalEmu)

```bash
./smokes/networking/ecs-hairpin-smoke.sh
```

The smoke:

1. Starts two Fargate-compat **awsvpc** tasks on one Docker host (server nginx + curl client).
2. Proves **direct** client → server ENI:8080.
3. Registers the server on an **internal NLB** IP target group (service VIP shape).
4. Has the **peer** client call the VIP (NLB DNS / VPC address).
5. Branches on whether host chain `AWSBOX-ELBV2` DNATs that VIP (client-IP retention path in [elbv2.md](elbv2.md)).

### Observed local behaviour

| Path | Real AWS (typical) | LocalEmu |
|------|--------------------|----------|
| Direct ENI task↔task | Works | Works |
| Same-host peer→NLB VIP with client-IP DNAT | Often **fails** (hairpin) | **Fails** when `AWSBOX-ELBV2` DNATs VIP→target on the Docker bridge — same failure class |
| LocalEmu process → its own VIP | n/a | Works (local delivery; never hits host `PREROUTING` DNAT) |
| Peer→VIP when host DNAT unavailable | Often works if retention off (proxy/SNAT) | Works via userspace TCP proxy; target may see proxy address ([#236](https://github.com/kgz/awsl/issues/236)) |
| Cross-host via same VIP | Works | N/A — every task shares one Docker host |

**Match:** with DNAT installed (normal `./bin/stackwrangler up` + working host iptables), peer→VIP fails and direct ENI succeeds — the awkward AWS path shows up locally. No separate Debt for “VIP should succeed”; that would *hide* the fidelity bug. Related retention/SG seeing the caller remains [#236](https://github.com/kgz/awsl/issues/236).

## Optional real-AWS parity

Not run by default. Creating NLB / ECS tasks in a real account needs **explicit approval** in-session ([aws-cost-approval](../.cursor/rules/aws-cost-approval.mdc)).

## Related

- Parent fidelity epic [#180](https://github.com/kgz/awsl/issues/180)
- ECS task-role DNAT [#154](https://github.com/kgz/awsl/issues/154)
- NLB client IP at target SG [#236](https://github.com/kgz/awsl/issues/236)
- ELBv2 data plane [elbv2.md](elbv2.md)
