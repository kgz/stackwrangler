# ELBv2 data plane

LocalEmu `elbv2` on `:4566` (`SERVICES` includes `elbv2`). Listeners are real sockets inside the LocalEmu container, not API stubs. Patches: `localemu-patches/elbv2_*.py` (#203). API Gateway VPC_LINK uses the same path (#267).

```bash
./bin/stackwrangler up --force    # remounts localemu-patches/elbv2_*.py
AWSBOX_ELBV2_E2E=1 ./bin/e2e.sh  # runs elbv2-smoke in e2e (off by default, #299)
./smokes/networking/elbv2-smoke.sh           # NLB/ALB forward, client IP, health, DNS, authz
./smokes/networking/elbv2-host-override-register-smoke.sh  # RegisterTargets keeps host_override (#603)
./smokes/apigw/apigw-nlb-ecs-smoke.sh   # VPC_LINK → internal NLB → ECS ip target
```

Profile `local` (from `./bin/stackwrangler up --force`) sends `elbv2` to the LocalEmu endpoint.

## What works

| Surface | Behaviour |
|---------|-----------|
| NLB TCP | Binds the listener port. Instance targets use the container address on the VPC bridge, not `127.0.0.1`. ECS bridge host ports set `Target.host_override` to `host.docker.internal` so health and forward dial the published host port (#247). IP targets use the registered address (join the LB VPC so LocalEmu can reach them). |
| NLB client IP | Host chain `AWSBOX-ELBV2` DNATs to healthy targets so `accept()` sees the caller. A userspace proxy is the fallback if that chain cannot be installed. |
| NLB TLS | Terminates with the ACM certificate attached to the listener (falls back to LocalEmu’s default when none is set) and forwards bytes. Create-time presentation is [#242](https://github.com/kgz/awsl/issues/242). Default-cert changes via `ModifyListener` (or first-default `AddListenerCertificates` on a cert-less listener) reload live handshake material ([#594](https://github.com/kgz/awsl/issues/594)); secondary Add is SNI-only and does not flip the default. |
| ALB HTTP | Default action plus host-header and path-pattern rules. The client `Host` is forwarded. |
| Health | TCP connect, or HTTP/HTTPS GET of `HealthCheckPath` honouring `Matcher.HttpCode`. `describe-target-health` and new connections skip `unhealthy` targets. |
| `host_override` | Internal dial address for ECS bridge host ports (`host.docker.internal`). Survives API `RegisterTargets` rebuilds ([#603](https://github.com/kgz/awsl/issues/603); set by [#247](https://github.com/kgz/awsl/issues/247)). |
| DNS | LocalEmu and workloads on the LB VPC get the name in `/etc/hosts` (VPC address). The host list is `.awsbox/elbv2.hosts` (edge address for internet-facing). |
| VPC_LINK | REST `HTTP_PROXY` integrations with NLB DNS as the URI resolve and forward through the TCP listener ([apigw-rest.md](apigw-rest.md)). |
| Scheme | Internal listeners bind the VPC address only, so the compose-network address refuses the port. |

Internet-facing listeners are reached at the LocalEmu container's compose-network IP (host → that IP works on Linux). Ports 80 and 443 are not published on the host, because those ports are often already taken.

## Gaps

- No console ([#241](https://github.com/kgz/awsl/issues/241)).
- Client-IP preservation depends on host iptables. If DNAT cannot be installed, targets see the proxy address. Security-group checks against that address are [#236](https://github.com/kgz/awsl/issues/236).
- ECS bridge-mode tasks behind an instance target group: the listener dials the EC2 container address, but bridge host ports are published on the Docker host. [#247](https://github.com/kgz/awsl/issues/247) sets `Target.host_override`; [#603](https://github.com/kgz/awsl/issues/603) keeps that override across `RegisterTargets`.
- Classic ELB is not this path.
- `elbv2-smoke.sh` needs EC2 containers; the mirror resource-id start.d patch breaks them on beta ([#299](https://github.com/kgz/awsl/issues/299)).
