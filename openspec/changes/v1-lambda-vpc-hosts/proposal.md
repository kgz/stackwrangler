## Why

Lambdas that run inside a VPC usually call private services through an internal hostname (an internal NLB, an ECS service). Locally, a function's container can only reach the host by the Docker bridge IP, and no hostnames resolve, so that hop can't be tested. LocalEmu already accepts `VpcConfig` and can pass extra Docker flags to function containers, so this needs config, not new emulation.

## What Changes

- `.env` setting `AWSBOX_LAMBDA_DOCKER_FLAGS` (default `--add-host=host.docker.internal:host-gateway`), passed to LocalEmu as `LAMBDA_DOCKER_FLAGS`. Users add `--add-host=<internal-name>:host-gateway` entries for the services they run on the host.
- `bin/lambda-vpc-smoke.sh`: creates a VPC, subnet and security group, deploys a VPC Lambda, and checks it reaches a throwaway HTTP server on the host by mapped hostname (happy) and fails to resolve an unmapped name (sad).
- Docs: `docs/lambda-vpc.md`, smoke matrix, test paths, README Lambda row.

## Non-goals

- Real ENIs, subnet routing or security-group enforcement (that belongs to #51)
- NLB data plane (#53)
- Console changes

## Capabilities

### New Capabilities

- `lambda-vpc-hosts`: VPC-configured Lambdas reach host services through configured hostnames

### Modified Capabilities

(none)

## Impact

- `docker-compose.yml`, `.env.example`, `bin/lambda-vpc-smoke.sh`, `bin/e2e.sh`, docs
- Issue: #186
