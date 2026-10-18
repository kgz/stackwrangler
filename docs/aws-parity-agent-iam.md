# Real-AWS parity — default credentials

Gate is your **default** IAM user (`~/.aws/credentials` `[default]`). No separate agent user.

Shell often has LocalEmu `AWS_ACCESS_KEY_ID=awsbox` set — that hits real AWS as InvalidClientTokenId. Parity scripts unset those.

```bash
./bin/aws-parity-iam-denied.sh
```

Creates `awsbox-parity-*` user + role (~$0 IAM), asserts AccessDenied / simulate deny, deletes on exit.

Requires your default user can create/delete IAM users, roles, policies, access keys, and call `iam:SimulatePrincipalPolicy` + `s3:ListAllMyBuckets` (denied temp user’s probe). Policy template: `docs/aws-parity-agent-policy.json` — attach only if default lacks those permissions.
