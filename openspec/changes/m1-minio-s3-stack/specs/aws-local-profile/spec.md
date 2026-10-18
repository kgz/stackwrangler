## ADDED Requirements

### Requirement: Write profile local for MinIO
The system SHALL provide a command that writes AWS shared profile `local` targeting the MinIO S3 endpoint with the stack credentials.

#### Scenario: Profile write after up
- **WHEN** MinIO is running and the user runs the profile write command
- **THEN** `aws --profile local s3 ls` exits zero against MinIO (empty list is success)

#### Scenario: Refuse foreign profile
- **WHEN** profile `local` exists and was not written by awsbox, and the user runs write without `--force`
- **THEN** the command exits non-zero without overwriting

### Requirement: Optional profile remove
The system SHALL support removing the awsbox-managed `local` profile entries on request.

#### Scenario: Remove profile
- **WHEN** the user runs the profile remove command after a write
- **THEN** profile `local` entries written by awsbox are gone
