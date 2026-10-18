## ADDED Requirements

### Requirement: Lambda console entry
The console SHALL provide a Lambda area at `/lambda` reachable from the fav-bar.

#### Scenario: Open Lambda
- **WHEN** the user opens `/lambda`
- **THEN** the Functions page loads and lists functions from the local Lambda API

### Requirement: Create hello function
The Functions page SHALL allow creating a hello Node.js function with one action.

#### Scenario: Create from empty
- **WHEN** the user creates a hello function with a unique name
- **THEN** the function appears in the list
