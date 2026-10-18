## ADDED Requirements

### Requirement: Compose starts MinIO S3 API
The repository SHALL provide a Docker Compose file that starts MinIO serving an S3-compatible API on the configured host port (default `9000`).

#### Scenario: Compose up
- **WHEN** the user runs `docker compose up -d` with Docker available
- **THEN** MinIO becomes reachable on the S3 API port and accepts requests with the configured root credentials

#### Scenario: Persist objects
- **WHEN** an object is uploaded and the stack is restarted
- **THEN** the object is still present (named volume or bind mount)

### Requirement: Documented environment defaults
The stack SHALL ship an `.env.example` with root access key, secret, and ports so a new clone can copy to `.env` and start without inventing credentials.

#### Scenario: Copy env example
- **WHEN** the user copies `.env.example` to `.env` and starts compose
- **THEN** MinIO starts using those credentials
