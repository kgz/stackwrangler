## ADDED Requirements

### Requirement: Profile local is written on up
On successful `awsbox up`, the system SHALL create or update the AWS shared config profile named `local` so the AWS CLI and SDKs target the LocalStack endpoint.

#### Scenario: Profile created
- **WHEN** `awsbox up` completes successfully
- **THEN** profile `local` exists with region, endpoint URL for LocalStack, and access credentials usable by `aws --profile local`

#### Scenario: Existing non-awsbox local profile
- **WHEN** profile `local` already exists and was not created by awsbox, and the user runs `awsbox up` without `--force`
- **THEN** the command exits non-zero without overwriting the profile

### Requirement: aws CLI can list S3 against local
After `awsbox up`, `aws --profile local s3 ls` SHALL succeed against the local endpoint (empty bucket list is success).

#### Scenario: Smoke list buckets
- **WHEN** LocalStack is up and profile `local` is configured
- **THEN** `aws --profile local s3 ls` exits zero

### Requirement: Optional profile removal on down
When the user passes a documented flag (e.g. `--remove-profile`) to `awsbox down`, the system SHALL remove the `local` profile entries that awsbox wrote.

#### Scenario: Down with remove-profile
- **WHEN** the user runs `awsbox down --remove-profile` after a successful up
- **THEN** profile `local` written by awsbox is removed from the AWS shared config
