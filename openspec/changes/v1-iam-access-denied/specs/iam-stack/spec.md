## ADDED Requirements

### Requirement: IAM emulator service in compose
The system SHALL run an IAM-capable emulator (LocalEmu) on `127.0.0.1:4566` with policy enforcement enabled, started by `./bin/awsbox up` alongside SeaweedFS.

#### Scenario: Stack up includes IAM
- **WHEN** the user runs `./bin/awsbox up`
- **THEN** the IAM endpoint on port 4566 accepts `iam list-users` with admin credentials

### Requirement: Shared admin credentials
The system SHALL configure the IAM emulator so `AWSBOX_ACCESS_KEY` / `AWSBOX_SECRET_KEY` act as admin (root) credentials.

#### Scenario: IAM list with profile local
- **WHEN** the stack is up and profile `local` is written
- **THEN** `aws --profile local iam list-users` exits zero
