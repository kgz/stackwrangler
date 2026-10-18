## ADDED Requirements

### Requirement: Invoke from console
The console SHALL let the user invoke a selected (or named) function and display the response payload.

#### Scenario: Invoke hello
- **WHEN** the user invokes a hello function with `{"ping":true}`
- **THEN** the UI shows a successful response containing the echoed or hello body

### Requirement: CLI invoke smoke
The system SHALL provide a script that creates (if needed) and invokes a hello function via the local profile/endpoint, exiting zero on success.

#### Scenario: Script invoke OK
- **WHEN** the operator runs the Lambda smoke script with the stack up
- **THEN** the script exits zero and prints the invoke payload
