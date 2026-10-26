# Route 53 private hosted zones

Workloads on a VPC Docker network resolve that VPC's private hosted zones. A second VPC does not.

`./bin/awsbox up --force` after pulling so the resolver process and the ECS/EC2/Lambda `--dns` hooks are loaded. The resolver is the same root process as [VPC Interface endpoint private DNS](vpce-private-dns.md) (`init/boot.d/20-vpce-resolver.py`; port 53 needs `NET_BIND_SERVICE`, which the gateway drops). It answers private zones first, then endpoint names, then forwards. It reads Route 53 and ELBv2 from `127.0.0.1:4566` (all pages). Names it does not own go to the upstream resolver (`8.8.8.8`, or `AWSBOX_DNS_UPSTREAM`, comma separated).

Code: `localemu-patches/dns_common.py` (wire codec, UDP/TCP 53 server, upstream forward, VPC address discovery) is shared by `r53_private_resolver.py` and `vpce_private_dns.py`.

## What resolves

From a container whose `--dns` is this emulator's address on that VPC network:

| Record | Answer |
|--------|--------|
| A / AAAA | The record values |
| CNAME | The CNAME, then the target (including an ELBv2 DNS name) |
| Alias to an ELBv2 DNS name | A record for this container's address on the VPC network |

An internal load balancer name is answered only for its own VPC. The address is where the [ELBv2 listener](elbv2.md) is bound, so `http://<private-cname>/` reaches the target when the listener is port 80.

EC2, ECS `awsvpc`, and Lambda `VpcConfig` get that `--dns` address from the VPCE hooks (`init/start.d/20-vpce-private-dns.py`, `ecs_task_manager.py`).

## Smoke

```bash
./bin/r53-private-smoke.sh
```

Uses host port `24566` (`AWSBOX_R53_HOST_PORT`) so it does not take over a stack already bound to `:4566`. `AWSBOX_R53_RECREATE=0` skips the force-recreate when the stack is already warm; `AWSBOX_R53_KEEP=1` leaves resources.

### EC2 step and #299

On unmodified `beta/full-flow-v1`, EC2 containers do not start while `init/start.d/20-mirror-resource-ids.py` is loaded ([#299](https://github.com/kgz/awsl/issues/299)), so the EC2 step fails there. Same gate as the ELBv2 smoke: the smoke is not in `bin/e2e.sh`. Either:

```bash
AWSBOX_R53_COMPOSE_OVERRIDE=/path/to/override.yml ./bin/r53-private-smoke.sh   # blank 20-mirror-resource-ids.py and 20-custom-ids.py
AWSBOX_R53_SKIP_EC2=1 ./bin/r53-private-smoke.sh                                # ECS-only, skips the EC2 check
```

Override file:

```yaml
services:
  localstack:
    volumes:
      - /dev/null:/etc/localemu/init/start.d/20-mirror-resource-ids.py:ro
      - /dev/null:/etc/localemu/init/start.d/20-custom-ids.py:ro
```

It checks:

- CNAME to an internal NLB DNS name resolves and HTTP connects from an ECS task in the associated VPC
- the same names do not resolve from an ECS task in another VPC
- alias to an internal ALB returns the same addresses as the ALB DNS name
- A and AAAA records
- upstream forwarding: a public name (`example.com`, `AWSBOX_R53_UPSTREAM_NAME`) resolves to a public address from both VPCs
- an EC2 instance in the associated VPC (needs the #299 override, or skipped with `AWSBOX_R53_SKIP_EC2=1`)
- IAM deny of `route53:ListHostedZones`

## Limits

- Every load balancer in a VPC answers as this container's address on that VPC network, not a distinct ENI per LB ([#245](https://github.com/kgz/awsl/issues/245)).
- Connect goes through the ELBv2 data plane ([elbv2.md](elbv2.md)).
- Alias to API Gateway and public zones for the host: [#300](https://github.com/kgz/awsl/issues/300).
- The EC2 step needs the #299 workaround above until that issue is fixed.
- No Route 53 console, and the Lambda `VpcConfig` hook is not in the smoke ([#245](https://github.com/kgz/awsl/issues/245)).
