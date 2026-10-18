## ADDED Requirements

### Requirement: Compose starts S3-compatible API
The repository SHALL provide a Docker Compose file that starts an S3-compatible API (SeaweedFS) on the configured host port (default `8333`).

#### Scenario: Compose up via awsbox
- **WHEN** the user runs `./bin/awsbox up` with Docker available
- **THEN** the S3 endpoint becomes reachable and accepts requests with the configured credentials

#### Scenario: Persist objects
- **WHEN** an object is uploaded and the stack is restarted
- **THEN** the object is still present (named volume)

### Requirement: Documented environment defaults
The stack SHALL ship an `.env.example` with access key, secret, region, and endpoint so a new clone can copy to `.env` and start.

#### Scenario: Copy env example
- **WHEN** the user runs `awsbox up` without an existing `.env`
- **THEN** `.env` is created from `.env.example` and the stack starts with those credentials
