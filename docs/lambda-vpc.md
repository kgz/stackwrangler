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

- `VpcConfig` attaches the function to `localemu-vpc-<vpc-id>` and may apply subnet route filters via a netns sidecar; there are still no real ENIs, and security-group rules are not enforced inside the Lambda container ([#51](https://github.com/kgz/awsl/issues/51), [#237](https://github.com/kgz/awsl/issues/237)). Package managers are never used to install iptables into the runtime image (that hung cold start; [#369](https://github.com/kgz/awsl/issues/369)).
- Mappings apply to every function, so a Lambda **without** `VpcConfig` can also reach mapped hosts. In AWS it couldn't reach private addresses ([#187](https://github.com/kgz/awsl/issues/187)).
- NLB/ALB forwarding is covered by [elbv2.md](elbv2.md). This smoke still hits the host directly.
- `DeleteVpc` removes the VPC's Docker network (disconnecting leftover endpoints first).
