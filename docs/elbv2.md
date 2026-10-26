# ELBv2 data plane

LocalEmu `elbv2` on `:4566` (`SERVICES` includes `elbv2`). Listeners are real sockets inside the LocalEmu container, not API stubs. Patches: `localemu-patches/elbv2_*.py` (#203). API Gateway VPC_LINK uses the same path (#267).

```bash
./bin/awsbox up --force    # remounts localemu-patches/elbv2_*.py
AWSBOX_ELBV2_E2E=1 ./bin/e2e.sh  # runs elbv2-smoke in e2e (off by default, #299)
./bin/elbv2-smoke.sh           # NLB/ALB forward, client IP, health, DNS, authz
./bin/apigw-nlb-ecs-smoke.sh   # VPC_LINK → internal NLB → ECS ip target
```

Profile `local` sends `elbv2` to the LocalEmu endpoint (`./bin/awsbox-profile write --force`).

## What works

| Surface | Behaviour |
|---------|-----------|
| NLB TCP | Binds the listener port. Instance targets use the container address on the VPC bridge, not `127.0.0.1`. IP targets use the registered address (join the LB VPC so LocalEmu can reach them). |
| NLB client IP | Host chain `AWSBOX-ELBV2` DNATs to healthy targets so `accept()` sees the caller. A userspace proxy is the fallback if that chain cannot be installed. |
| NLB TLS | Terminates with the LocalEmu certificate and forwards bytes. The listener ACM ARN is not the keypair ([#242](https://github.com/kgz/awsl/issues/242)). |
| ALB HTTP | Default action plus host-header and path-pattern rules. The client `Host` is forwarded. |
| Health | TCP probe. `describe-target-health` and new connections skip `unhealthy` targets. HTTP status matching is [#243](https://github.com/kgz/awsl/issues/243). |
| DNS | LocalEmu and workloads on the LB VPC get the name in `/etc/hosts` (VPC address). The host list is `.awsbox/elbv2.hosts` (edge address for internet-facing). |
| VPC_LINK | REST `HTTP_PROXY` integrations with NLB DNS as the URI resolve and forward through the TCP listener ([apigw-rest.md](apigw-rest.md)). |
| Scheme | Internal listeners bind the VPC address only, so the compose-network address refuses the port. |

Internet-facing listeners are reached at the LocalEmu container's compose-network IP (host → that IP works on Linux). Ports 80 and 443 are not published on the host, because those ports are often already taken.

## Gaps

- No console ([#241](https://github.com/kgz/awsl/issues/241)).
- TLS does not load the ACM certificate attached to the listener ([#242](https://github.com/kgz/awsl/issues/242)).
- Health checks are TCP connects. An HTTP 5xx still counts as healthy ([#243](https://github.com/kgz/awsl/issues/243)).
- Client-IP preservation depends on host iptables. If DNAT cannot be installed, targets see the proxy address. Security-group checks against that address are [#236](https://github.com/kgz/awsl/issues/236).
- Classic ELB is not this path.
- `elbv2-smoke.sh` needs EC2 containers; the mirror resource-id start.d patch breaks them on beta ([#299](https://github.com/kgz/awsl/issues/299)).
