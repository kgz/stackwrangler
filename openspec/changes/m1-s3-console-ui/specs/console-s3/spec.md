## ADDED Requirements

### Requirement: List general purpose buckets
The console SHALL list buckets via `ListBuckets` on the General purpose buckets view.

#### Scenario: Empty
- **WHEN** there are no buckets
- **THEN** an empty state is shown with a Create bucket action

#### Scenario: With buckets
- **WHEN** buckets exist
- **THEN** their names and creation dates appear in the table

### Requirement: Create bucket
The console SHALL create a bucket via `CreateBucket` when the user confirms Create bucket.

#### Scenario: Success
- **WHEN** the user creates a valid bucket name
- **THEN** `CreateBucket` is called and the list refreshes

### Requirement: Browse objects
Opening a bucket SHALL list objects via `ListObjectsV2` and allow upload (`PutObject`), download (`GetObject`), and delete (`DeleteObject`).

#### Scenario: Upload and list
- **WHEN** the user uploads a file into a bucket
- **THEN** it appears in the object list after refresh

### Requirement: Surface S3 errors
API failures SHALL show the S3 error code/message in the UI (e.g. `AccessDenied`, `NoSuchBucket`).

#### Scenario: Missing bucket
- **WHEN** the user opens a bucket that does not exist
- **THEN** the UI shows the error from the API response
