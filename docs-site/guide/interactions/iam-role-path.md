# IAM role path in resource ARN

Role-addressed IAM APIs (`GetRole`, `PutRolePolicy`, `TagRole`, `CreateRole`, …) authorise against the role’s **full** ARN, including its IAM path — e.g. `arn:aws:iam::acct:role/team/app/target-role`. For `CreateRole`, the path comes from the request `Path` before the role exists. Policies scoped to `role/team/app/*` match; `role/other/path/*` does not.

**Status:** shipped

## Sequence

1. Create a role with `--path /team/app/` (admin setup) and a caller Allowed on `role/team/app/*`.
2. Assume that caller: `get-role` / `put-role-policy` by **name**, and `create-role --path /team/app/` — expect allow.
3. Same calls with a caller scoped to `role/other/path/*` — expect AccessDenied citing the pathed ARN (including CreateRole’s request Path).

## Prove it

```bash
./smokes/security/iam-role-path-arn-smoke.sh
```
