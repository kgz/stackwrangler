# Custom resource IDs and account id

Local creates can use the same ids as a real account. Set a `_custom_id_` tag (or the hosted-zone equivalent below) on create. The value is checked; a bad value fails the create.

The account id embedded in ARNs comes from the access key:

| Env | Meaning |
|-----|---------|
| `AWSBOX_ACCOUNT_IDS` | Comma-separated `access_key=012345678901`. This key uses this account. |
| `AWSBOX_ACCOUNT_ID` | 12 digits. Used when the key is not in the map and would otherwise be `000000000000`. |

Per-key entries win. Restart `./bin/stackwrangler up` after changing either value. STS `GetCallerIdentity` and resource `OwnerId` fields return that account. The console account chip is `VITE_AWS_ACCOUNT_ID` ([#215](https://github.com/kgz/awsl/issues/215)), not this env.

Patch: `localemu-patches/init/start.d/20-custom-ids.py` (mounted with the other start scripts). Moto already honours `_custom_id_` for REST APIs via `@moto_id`; the patch wires the types that never consulted that helper.

## Supported types

| Resource | How to set the id | Format |
|----------|-------------------|--------|
| VPC | Tag `_custom_id_` on `CreateVpc` | `vpc-` + 8 or 17 hex |
| Subnet | Tag `_custom_id_` on `CreateSubnet` | `subnet-` + 8 or 17 hex |
| Security group | Tag `_custom_id_` on `CreateSecurityGroup` | `sg-` + 8 or 17 hex |
| Route table | Tag `_custom_id_` on `CreateRouteTable` | `rtb-` + 8 or 17 hex |
| Internet gateway | Tag `_custom_id_` on `CreateInternetGateway` | `igw-` + 8 or 17 hex |
| VPC peering | Tag `_custom_id_` on `CreateVpcPeeringConnection` | `pcx-` + 8 or 17 hex |
| EC2 instance | Tag `_custom_id_` on `RunInstances` | `i-` + 8 or 17 hex. `MinCount` and `MaxCount` must be 1 |
| Load balancer | Tag `_custom_id_` on `CreateLoadBalancer` | 16 hex. That is the ARN suffix. Moto still builds `arn:…:loadbalancer/app/<name>/<suffix>` (including for NLB) and puts the configured account id in the ARN |
| Target group | Tag `_custom_id_` on `CreateTargetGroup` | 16 hex ARN suffix: `arn:…:targetgroup/<name>/<suffix>` |
| REST API | Tag `_custom_id_` on `CreateRestApi` | LocalEmu native: lowercase only (no length check) |
| HTTP API | Tag `_custom_id_` on `CreateApi` | 10 chars, `[a-z0-9]` |
| Hosted zone | `CallerReference` prefixed with `_custom_id_:` (CreateHostedZone has no tags). A `<Tags>` entry with key `_custom_id_` is also accepted | `Z` + 13 to 32 chars from `A-Z` and `0-9` |
| ECS cluster | Tag `_custom_id_` on `CreateCluster` | Full ARN `arn:<partition>:ecs:<region>:<account>:cluster/<ClusterName>`. The name segment must match `ClusterName` |

An id that is already in use, or that fails the pattern, is rejected (`InvalidParameterValue`, `ValidationError`, `BadRequestException`, or `InvalidInput`, depending on the service).

Untagged creates keep moto's generated ids.

## Example

```bash
aws --endpoint-url http://127.0.0.1:4566 --profile local ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=_custom_id_,Value=vpc-0123456789abcdef0}]'
```

Smoke: `./bin/custom-id-smoke.sh`.
