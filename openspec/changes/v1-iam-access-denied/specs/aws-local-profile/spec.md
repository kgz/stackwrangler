## ADDED Requirements

### Requirement: Per-service endpoints on profile local
When writing profile `local`, the system SHALL configure S3 to the SeaweedFS endpoint and IAM/STS to the LocalStack endpoint.

#### Scenario: S3 still hits SeaweedFS
- **WHEN** profile `local` is written after stack up
- **THEN** `aws --profile local s3 ls` talks to the SeaweedFS endpoint (port 8333 by default)

#### Scenario: IAM hits LocalStack
- **WHEN** profile `local` is written after stack up
- **THEN** `aws --profile local iam list-users` talks to LocalStack (port 4566 by default)
