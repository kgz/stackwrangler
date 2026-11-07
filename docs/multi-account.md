# Multiple accounts

One LocalEmu process can hold more than one account. The access key selects the account. IAM, STS, and S3 state for that account stay separate from the others.

Patch: `localemu-patches/init/start.d/21-multi-account.py` (mounted with the other start scripts). Restart `./bin/stackwrangler up` after changing the env.

## Account from the access key

| Env | Meaning |
|-----|---------|
| `AWSBOX_ACCOUNT_IDS` | Comma-separated `access_key=012345678901`. This key is root in that account. |
| `AWSBOX_ACCOUNT_ID` | 12 digits. Used when the key is not in the map and would otherwise be `000000000000`. |

Per-key entries win. A key created inside an account (`AKIA…` user key, `ASIA…` `AssumeRole` session) stays on that account when the account id is one of the values above, or the default `000000000000`. A production `AKIA` / `ASIA` key whose account is not in that set still resolves to the default account.

Listing buckets was already per account. `HeadBucket` and object calls on another account's bucket return Access Denied unless that bucket's policy Allows the caller (identity policy must also Allow). Compose also sets `MOTO_S3_ALLOW_CROSSACCOUNT_ACCESS=false` for the moto S3 path.

```bash
# .env — then ./bin/stackwrangler up
AWSBOX_ACCOUNT_IDS=awsbox-a=111111111111,awsbox-b=222222222222,awsbox-c=333333333333
```

`GetCallerIdentity` for `awsbox-a` / `awsbox-b` / `awsbox-c` returns those account ids. The smoke signs them with `AWSBOX_SECRET_KEY`. The console account chip is still [#215](https://github.com/kgz/awsl/issues/215).

## Cross-account AssumeRole

A role in account B is assumable when its trust policy allows the caller. The form this covers:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<account-A>:root" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "example" } }
  }]
}
```

`arn:aws:iam::<account>:root` matches every principal in that account. Account C does not match. The caller also needs an identity policy that allows `sts:AssumeRole` (root skips that check).

The session key is an `ASIA` key for B. `GetCallerIdentity` with those credentials returns B. B's buckets and roles are what that session can see. A's resources are not in the list.

Trust statements honour:

| Condition | Behaviour |
|-----------|-----------|
| `StringEquals` `sts:ExternalId` | Must equal `ExternalId` on the call. A list means any value. |
| `Bool` `aws:MultiFactorAuthPresent` = `true` | Call must include `SerialNumber`. |
| `StringEquals` `aws:SourceAccount` | Set when a service assumes the role: from the calling resource ARN's account when present, otherwise (Lambda only) the role's account. A user call never satisfies it. |
| `ArnLike` / `ArnEquals` `aws:SourceArn` | Set from the calling resource (function / rule / topic ARN) when a service assumes the role. A list means any value. A user call never satisfies it. |
| Anything else (`aws:PrincipalOrgID`, …) | That statement does not apply. |

`Action` must be `sts:AssumeRole`, `sts:*`, or `*`. An explicit `Deny` that matches wins. Service principals (`lambda.amazonaws.com` and the rest) are unchanged.

Organizations (OU, SCP) are not evaluated. Cross-account secret / key / bucket access needs Allow on both the caller identity policy and the resource policy (`./smokes/security/resource-policy-cross-account-smoke.sh`).

Smoke: `./smokes/security/multi-account-smoke.sh`. Lambda trust `aws:SourceAccount` / `aws:SourceArn`: `./smokes/lambda/lambda-trust-condition-smoke.sh`, `./smokes/lambda/lambda-trust-sourcearn-smoke.sh`.
