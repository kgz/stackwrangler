## Context

SeaweedFS owns general-purpose S3. IAM policy evaluation needs LocalStack. Vision already points at LocalStack for IAM/Lambda/APIGW tracks.

## Goals / Non-Goals

**Goals:**

- `./bin/awsbox up` starts SeaweedFS + LocalStack
- Profile `local`: S3 → `:8333`, IAM/STS → `:4566`
- Console IAM: list users; one-click AccessDenied learning path
- CLI script asserts `AccessDenied` from a deny policy

**Non-Goals:**

- Move general buckets UI onto LocalStack S3
- Full IAM console or Identity Center
- Lambda execution roles (follow-on)

## Decisions

1. **LocalEmu (`localemu/localemu`) for IAM/STS (+ S3 for demos)**  
   Free IAM API with `IAM_ENFORCEMENT=1` (LocalStack community does not enforce).
   SeaweedFS stays the S3 console backend. Compose service keeps the name `localstack`
   so later tracks can swap images without renames.

2. **Per-service endpoints in profile `local`**  
   AWS CLI `services` block: `s3` → SeaweedFS, `iam`/`sts` → LocalStack. Admin keys stay `AWSBOX_*`.

3. **AccessDenied demo uses LocalStack S3**  
   Create user + deny `s3:ListAllMyBuckets`, call ListBuckets with that user’s keys against `:4566`. SeaweedFS never sees the deny policy.

4. **Fav-bar IAM → `/iam` app shell**  
   Minimal: Users table + “AccessDenied lab” panel. S3 sidebar unchanged when on S3 routes.

5. **Same admin keys for LocalStack**  
   `AWSBOX_ACCESS_KEY` / `SECRET` as LocalStack default credentials so one profile works.

## Risks / Trade-offs

- [Two S3 backends] → Label learning path “policy demo (LocalStack)”; general buckets stay SeaweedFS
- [LocalStack cold start] → health wait on `/_localstack/health`
- [CLI services config support] → require AWS CLI v2; document if missing

## Migration Plan

Compose adds `localstack` service; existing SeaweedFS volume unchanged. `awsbox-profile write --force` refreshes endpoints.

## Open Questions

- None for this change; Lambda will reuse the same LocalStack container later.
