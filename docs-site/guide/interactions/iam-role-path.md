# IAM role path in resource ARN

Role-addressed IAM APIs (`GetRole`, `PutRolePolicy`, `TagRole`, …) authorise against the role’s **full** ARN, including its IAM path — e.g. `arn:aws:iam::acct:role/team/app/target-role`. Policies scoped to `role/team/app/*` match; `role/other/path/*` does not.

**Status:** shipped

## Sequence

1. Create a role with `--path /team/app/`.
2. Assume a caller whose inline policy Allows those actions on `role/team/app/*`.
3. Call `get-role` / `put-role-policy` by **name** — expect allow.
4. Same calls with a caller scoped to `role/other/path/*` — expect AccessDenied citing the pathed ARN.

## Prove it

```bash
./smokes/security/iam-role-path-arn-smoke.sh
```
