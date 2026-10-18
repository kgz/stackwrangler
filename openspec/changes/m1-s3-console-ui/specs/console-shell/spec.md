## ADDED Requirements

### Requirement: AWS-style console chrome
The console SHALL present a dark top bar with AWS-like branding mark, search placeholder, region label, and account id, plus an S3 service sidebar.

#### Scenario: Open home
- **WHEN** the user opens the console root URL
- **THEN** they see the global header and can navigate to Amazon S3 buckets

### Requirement: Region and account display
The console SHALL show a configurable region string and account id in the header (defaults from env).

#### Scenario: Defaults
- **WHEN** env provides region and account id
- **THEN** those values appear in the header
