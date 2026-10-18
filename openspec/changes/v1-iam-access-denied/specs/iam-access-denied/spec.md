## ADDED Requirements

### Requirement: AccessDenied learning path in console
The IAM console SHALL offer a learning action that creates a restricted IAM user (deny S3 list), attempts ListBuckets with that user’s credentials against LocalStack S3, and surfaces `AccessDenied`.

#### Scenario: Lab produces AccessDenied
- **WHEN** the user runs the AccessDenied lab from the IAM console
- **THEN** the UI shows an error containing `AccessDenied` (or equivalent denial code)

### Requirement: CLI AccessDenied assertion
The system SHALL provide a script that creates a deny-policy user, attempts an S3 list with that user’s keys against LocalStack, and exits zero only when the call is denied.

#### Scenario: Script asserts denial
- **WHEN** the stack is up and the operator runs the IAM AccessDenied script
- **THEN** the script exits zero after observing AccessDenied
