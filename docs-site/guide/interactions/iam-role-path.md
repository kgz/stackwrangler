# IAM role path in resource ARN

Role-addressed IAM APIs (`GetRole`, `PutRolePolicy`, `TagRole`, `CreateRole`, …) authorise against the role’s **full** ARN, including its IAM path — e.g. `arn:aws:iam::acct:role/team/app/target-role`. For `CreateRole`, the path comes from the request `Path` before the role exists. Policies scoped to `role/team/app/*` match; `role/other/path/*` does not.

CloudFormation’s `AWS::IAM::Role` handler calls `iam:GetRole` **before** `CreateRole`. A role that does not exist yet is authorised as pathless `role/<name>`, so path-scoped `CreateRole` grants alone get AccessDenied on GetRole until a second grant covers `role/<name-prefix>-*` for GetRole / DeleteRolePolicy / …. On a new stack that failure’s rollback still probes those pathless cleanup APIs and ends `DELETE_FAILED`.

**Status:** shipped

## Sequence

1. Create a role with `--path /team/app/` (admin setup) and a caller Allowed on `role/team/app/*`.
2. Assume that caller: `get-role` / `put-role-policy` by **name**, and `create-role --path /team/app/` — expect allow.
3. Same calls with a caller scoped to `role/other/path/*` — expect AccessDenied citing the pathed ARN (including CreateRole’s request Path).
4. Deploy `AWS::IAM::Role` with `Path` as a role that only has `CreateRole` on `role/<path>/*` — expect `iam:GetRole` AccessDenied on pathless `role/<name>`; add the pathless grant and expect `CREATE_COMPLETE`.

## Prove it

```bash
./smokes/security/iam-role-path-arn-smoke.sh
./smokes/iac/cfn-path-scoped-role-smoke.sh
```
