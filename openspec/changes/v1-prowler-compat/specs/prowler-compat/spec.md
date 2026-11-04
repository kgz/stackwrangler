## ADDED Requirements

### Requirement: Isolated Prowler smoke

The system SHALL provide `./smokes/security/prowler-smoke.sh` that runs Prowler against LocalEmu using an isolated AWS config (dummy awsbox credentials and local endpoint only, via `env -i` or equivalent) so no call can use the operator's real AWS credentials. The smoke SHALL run with `--log-level ERROR` (or equivalent) and report the distinct failing API calls.

#### Scenario: Smoke completes against local stack

- **WHEN** LocalEmu is up and `./smokes/security/prowler-smoke.sh` is run
- **THEN** Prowler finishes without contacting real AWS and prints the distinct failing API call names

### Requirement: Failing-API baseline ratchet

The system SHALL keep a checked-in baseline of distinct failing API calls (or their count). The smoke SHALL fail when the number of distinct failing API calls rises above that baseline.

#### Scenario: Regression increases failures

- **WHEN** a new API call fails that was not in the baseline set / count
- **THEN** `./smokes/security/prowler-smoke.sh` exits non-zero

### Requirement: S3 Control reachability and public-access reads

S3 Control account-level calls used by Prowler (`GetPublicAccessBlock`, `ListAccessPoints`, `ListMultiRegionAccessPoints`) SHALL succeed against the local endpoint so Prowler's S3 public-access checks produce results rather than being skipped for hostname or unimplemented errors.

#### Scenario: Account public access block readable

- **WHEN** a client calls S3 Control `GetPublicAccessBlock` for the local account via the smoke's endpoint
- **THEN** the call returns a valid response (including default/empty public access block state)

### Requirement: Empty read APIs for scanner services

LocalEmu SHALL expose the services Prowler probes for empty-account reads (at minimum: SSM, CloudWatch alarms, CloudTrail, Organizations, Backup, Batch, Application Auto Scaling, and DAX when available) such that describe/list calls return valid empty responses rather than "service not enabled" failures.

#### Scenario: Describe with no resources

- **WHEN** Prowler calls `cloudwatch:DescribeAlarms` (or equivalent empty reads for the listed services) on a fresh awsbox account
- **THEN** the API returns success with an empty result set

### Requirement: Documentation

The project SHALL document how to run Prowler against awsl, including the isolation setup, and SHALL update the README status table for Prowler compatibility.

#### Scenario: Operator follows docs

- **WHEN** an operator reads `docs/prowler.md` and runs the documented command
- **THEN** they can execute the isolated Prowler smoke without using real AWS credentials
