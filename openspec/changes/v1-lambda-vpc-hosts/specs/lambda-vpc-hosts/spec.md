## ADDED Requirements

### Requirement: Configurable host mappings for Lambda containers
The stack SHALL pass `AWSBOX_LAMBDA_DOCKER_FLAGS` from `.env` to the emulator as `LAMBDA_DOCKER_FLAGS`, defaulting to `--add-host=host.docker.internal:host-gateway`.

#### Scenario: Default mapping
- **WHEN** the stack starts without `AWSBOX_LAMBDA_DOCKER_FLAGS` set
- **THEN** a Lambda can reach an HTTP server on the host at `host.docker.internal`

#### Scenario: Custom internal name
- **WHEN** `.env` adds `--add-host=<name>:host-gateway` and the stack restarts
- **THEN** a Lambda can reach the host server at `<name>`

### Requirement: VPC Lambda smoke
The system SHALL provide `bin/lambda-vpc-smoke.sh`, which deploys a Lambda with `VpcConfig` and exits zero only when the mapped hostname is reachable and an unmapped hostname fails to resolve.

#### Scenario: Happy and sad paths
- **WHEN** the operator runs the smoke with the stack up
- **THEN** it reports the mapped call returning 200 and the unmapped call failing with `ENOTFOUND`, and exits zero
