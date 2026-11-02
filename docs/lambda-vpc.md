# Lambda in a VPC → services on your machine

Lambdas that run in a VPC usually call private services by an internal hostname (an internal NLB, an ECS service). In awsbox, each function runs in its own Docker container, and only the hostnames you map resolve.

## Setup

`.env`:

```bash
# one --add-host per name your functions call; host-gateway = your machine
AWSBOX_LAMBDA_DOCKER_FLAGS=--add-host=host.docker.internal:host-gateway --add-host=internal-nlb.example:host-gateway
```

Restart the emulator after changing it: `./bin/awsbox up --force`.

The value is passed through as LocalEmu's `LAMBDA_DOCKER_FLAGS`, so any `docker run` flag works (for example `--network <name>` to join another compose network). `host-gateway` needs Docker 20.10+.

A function then reaches a service listening on your machine at `http://internal-nlb.example:<port>/`. The service must listen on `0.0.0.0` (or the Docker bridge), not only `127.0.0.1`.

## Smoke

```bash
./bin/lambda-vpc-smoke.sh
AWSBOX_LAMBDA_SMOKE_HOST=internal-nlb.example ./bin/lambda-vpc-smoke.sh   # also checks your own mapping
```

It creates a VPC, subnet and security group, deploys a Lambda with `VpcConfig`, starts a throwaway HTTP server on the host, and checks that the mapped name returns 200 (happy) and an unmapped name fails with `ENOTFOUND` (sad).

## Fidelity gaps

- `VpcConfig` attaches the function to `localemu-vpc-<vpc-id>` and applies subnet route filters plus security-group `SG_IN` / `SG_OUT` via a privileged alpine netns sidecar (same as ECS awsvpc). There are still no real ENIs ([#51](https://github.com/kgz/awsl/issues/51)). Package managers are never used to install iptables into the runtime image (that hung cold start; [#369](https://github.com/kgz/awsl/issues/369)). Membership and egress coverage: `./bin/sg-enforcement-smoke.sh` ([sg-enforcement.md](sg-enforcement.md)).
- Mappings apply to every function, so a Lambda **without** `VpcConfig` can also reach mapped hosts. In AWS it couldn't reach private addresses ([#187](https://github.com/kgz/awsl/issues/187)).
- NLB/ALB forwarding is covered by [elbv2.md](elbv2.md). This smoke still hits the host directly.
- `DeleteVpc` removes the VPC's Docker network (disconnecting leftover endpoints first).
- `AttachInternetGateway` does not recreate or orphan `localemu-vpc-*`; route-table egress is covered by [vpc-routing.md](vpc-routing.md) and `./bin/vpc-egress-smoke.sh` ([#386](https://github.com/kgz/awsl/issues/386)).
