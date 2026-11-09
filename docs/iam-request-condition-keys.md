# IAM request-parameter condition keys

Keys that come from **API request parameters** (not service-origin context). Stock LocalEmu `_build_conditions` sets globals (`aws:PrincipalArn`, `aws:RequestedRegion`, …), tag keys (`aws:RequestTag/*`, `aws:TagKeys`, `aws:ResourceTag/*`), and a few S3 access-point keys. Patches add `iam:PassedToService` ([oidc.md](oidc.md)) and `sns:Protocol` / `sns:Endpoint` on Subscribe (#518).

Service-origin keys (`kms:ViaService`, calling-service `aws:SourceArn` / `aws:SourceAccount`) are separate — see [#223](https://github.com/kgz/awsl/issues/223). Policy simulation without wiring ContextEntries is [#517](https://github.com/kgz/awsl/issues/517).

## Populated (request-parameter)

| Key | When | Smoke |
|-----|------|-------|
| `sns:Protocol`, `sns:Endpoint` | `sns:Subscribe` from `Protocol` / `Endpoint` | `./smokes/messaging/sns-subscribe-conditions-smoke.sh` |
| `aws:RequestTag/*`, `aws:TagKeys` | tag-on-create params | (enforcer) |
| `iam:PassedToService` | PassRole field scan | `./smokes/security/oidc-smoke.sh` |
| `lambda:FunctionArn` | Create from `FunctionName`; Get/Update/Delete from mapping | `./smokes/security/lambda-esm-function-arn-smoke.sh` · [#650](https://github.com/kgz/stackwrangler/issues/650) |

## Gaps (documented request keys the enforcer does not set yet)

Focus: services on the local serverless / authz path. Not an exhaustive SAR dump.

| Service | Missing request-parameter keys (examples) | Notes |
|---------|---------------------------------------------|-------|
| **IAM** | `iam:PermissionsBoundary` on `CreateRole` / `PutRolePolicy` / `AttachRolePolicy` | Same request-parameter class as SNS Subscribe; tracked / fixed in [#525](https://github.com/kgz/awsl/issues/525) (PR [#581](https://github.com/kgz/stackwrangler/pull/581)) — not yet on `main` |
| **KMS** | `kms:EncryptionContext`, `kms:EncryptionContextKeys`, `kms:EncryptionAlgorithm`, `kms:KeyUsage` / `kms:KeySpec` (CreateKey), `kms:BypassPolicyLockoutSafetyCheck`, grant constraint keys | Crypto-context conditions common in least-privilege; ViaService is [#223](https://github.com/kgz/awsl/issues/223) |
| **DynamoDB** | `dynamodb:LeadingKeys`, `dynamodb:Attributes`, `dynamodb:Select`, `dynamodb:ReturnValues`, `dynamodb:ReturnConsumedCapacity` | FGAC / attribute-level policies fail closed |
| **S3** | `s3:prefix`, `s3:delimiter`, `s3:x-amz-acl`, `s3:x-amz-copy-source`, `s3:VersionId`, `s3:object-lock-*`, … | List/Get scoping by prefix is a frequent gap |
| **Lambda** | `lambda:Principal`, `lambda:FunctionUrlAuthType`, `lambda:CodeSigningConfigArn`, `lambda:SecurityGroupIds` / `lambda:SubnetIds`, `lambda:EventSourceToken`, … | AddPermission / URL / VPC create paths |
| **SQS** | mostly tag/resource today; few exclusive request keys | Low urgency vs SNS Subscribe |
| **Secrets Manager** | `secretsmanager:Name`, `secretsmanager:Resource/AllowPublicPolicy`, … | Name-based Allows |
| **STS** | `sts:ExternalId` is evaluated via trust; `sts:RoleSessionName` / `sts:SourceIdentity` / `sts:TransitiveTagKeys` as request keys may be incomplete | Multi-account ExternalId covered in smoke |
| **SNS** (beyond Subscribe) | Protocol/Endpoint on other subscription ops if AWS sets them from stored subscription | Subscribe fixed in #518 |

No new Debt tickets filed from this survey: none of the remaining gaps were scored Impact ≥ 4 for the Trust cut in this pass (SNS Subscribe was the high-Impact blocker). Re-score when a least-privilege deploy path hits one.
