## ADDED Requirements

### Requirement: awsbox up starts LocalStack
The `awsbox up` command SHALL start LocalStack via Docker Compose so the AWS API endpoint is available on the configured host port (default `4566`).

#### Scenario: First successful up
- **WHEN** the user runs `awsbox up` with Docker available and port free
- **THEN** LocalStack becomes healthy and the command exits successfully after printing the endpoint and profile name

#### Scenario: Docker unavailable
- **WHEN** the user runs `awsbox up` and Docker cannot be reached
- **THEN** the command exits non-zero with an error naming Docker as the missing dependency

### Requirement: awsbox down stops LocalStack
The `awsbox down` command SHALL stop and remove the LocalStack containers started by `awsbox up` for this project.

#### Scenario: Down after up
- **WHEN** LocalStack was started with `awsbox up` and the user runs `awsbox down`
- **THEN** the LocalStack containers for this project are stopped and removed

### Requirement: awsbox status reports stack health
The `awsbox status` command SHALL report whether LocalStack is running and healthy for this project.

#### Scenario: Status while running
- **WHEN** LocalStack is healthy and the user runs `awsbox status`
- **THEN** the output indicates running/healthy and includes the endpoint URL
