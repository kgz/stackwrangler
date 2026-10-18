## ADDED Requirements

### Requirement: IAM console entry
The console SHALL provide an IAM area at `/iam` reachable from the top fav-bar IAM control.

#### Scenario: Open IAM
- **WHEN** the user activates the IAM fav-bar control
- **THEN** the Users page loads and lists IAM users from LocalStack

### Requirement: Users list
The IAM Users page SHALL list user names from the local IAM API.

#### Scenario: Empty account
- **WHEN** no IAM users exist
- **THEN** the page shows an empty state without erroring
