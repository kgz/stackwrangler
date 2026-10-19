## ADDED Requirements

### Requirement: REST API from OpenAPI with Lambda authorizer
The stack SHALL support importing a REST API from an OpenAPI 3 document whose routes use `aws_proxy` Lambda integrations, with or without a REQUEST Lambda authorizer.

#### Scenario: Public route
- **WHEN** a route without security is called with a query string
- **THEN** the handler receives the path, method and query parameters and the response is 200

#### Scenario: Authorized route
- **WHEN** a secured route is called with a token the authorizer allows
- **THEN** the response is 200 and the authorizer's context reaches `requestContext.authorizer`

#### Scenario: Missing or denied token
- **WHEN** a secured route is called without the identity source, or with a token the authorizer denies
- **THEN** the response is 401 (AWS returns 403 for Deny; tracked as a gap)

### Requirement: Custom domain control plane
The stack SHALL allow creating an API Gateway custom domain (with an ACM certificate) and a base-path mapping to a REST API stage.

#### Scenario: Domain and mapping created
- **WHEN** the smoke requests a certificate, creates a domain and maps it to the stage
- **THEN** `get-domain-name` and `get-base-path-mappings` return them

### Requirement: REST smoke
The system SHALL provide `bin/apigw-rest-smoke.sh`, which exits zero only when every happy and sad check above holds and cleans up what it created.

#### Scenario: Smoke passes
- **WHEN** the operator runs the smoke with the stack up
- **THEN** it prints each check and exits zero
