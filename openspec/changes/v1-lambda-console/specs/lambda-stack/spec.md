## ADDED Requirements

### Requirement: Lambda service on local emulator
The system SHALL expose Lambda (and Logs) on the LocalEmu endpoint started by `./bin/awsbox up`, with Docker available for function runtimes.

#### Scenario: List functions via profile local
- **WHEN** the stack is up and profile `local` is written
- **THEN** `aws --profile local lambda list-functions` exits zero

### Requirement: Docker socket for runtimes
The LocalEmu container SHALL mount the host Docker socket so CreateFunction/Invoke can run container-backed runtimes.

#### Scenario: Invoke returns payload
- **WHEN** a hello Node function exists and is invoked with a JSON payload
- **THEN** the invoke response StatusCode is 200 and the payload is readable
