## ADDED Requirements

### Requirement: Lambda and Logs endpoints on profile local
When writing profile `local`, the system SHALL route `lambda` and `logs` to the LocalEmu endpoint (same as IAM/STS).

#### Scenario: lambda uses LocalEmu
- **WHEN** profile `local` is written after stack up
- **THEN** `aws --profile local lambda list-functions` talks to port 4566 by default
