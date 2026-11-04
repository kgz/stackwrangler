# Account mirror (`awsl mirror` / `awsl apply`)

Synthetic topology fixtures for the local emulator. This pass applies a VPC, subnet, route table, and security group, including arbitrary resource tags so tag-filtered Terraform data sources resolve. Reading a real account is [#220](https://github.com/kgz/awsl/issues/220) — `mirror` does not call AWS.

## Commands

```bash
./bin/awsl mirror dry-run
./bin/awsl apply testdata/mirror/synthetic-vpc.json
./bin/awsl apply testdata/mirror/tagged-vpc.json
# same entry points:
./bin/stackwrangler mirror dry-run
./bin/stackwrangler apply testdata/mirror/synthetic-vpc.json
```

`mirror` without `dry-run` exits 2. It does not call AWS and does not write a fixture.

`mirror --out <dir>` checks the path, then still refuses to read:

- A path inside this repo is refused unless `git check-ignore` matches it.
- A path outside the repo, or a gitignored path, is allowed as a destination but nothing is written yet.

`mirror dry-run` prints the read APIs a later pass would call, and the calls it will not make (`GetSecretValue`, `GetParameter`, task-definition environment, Lambda environment). No client calls go out.

`apply` creates resources on `AWSBOX_IAM_ENDPOINT` (default `http://127.0.0.1:4566`). The host must be loopback (`127.0.0.1`, `localhost`, `::1`, or `*.localhost`). Any other endpoint, including real AWS, is refused before the CLI runs.

## Fixture

Schema: [testdata/mirror/schema.json](../testdata/mirror/schema.json) (`awsl.mirror/v1`).

Examples (no account data, no secrets):

- [testdata/mirror/synthetic-vpc.json](../testdata/mirror/synthetic-vpc.json) — minimal VPC/subnet/SG
- [testdata/mirror/tagged-vpc.json](../testdata/mirror/tagged-vpc.json) — Name / CDK subnet tags / `Tier=private` route tables

| Field | Meaning |
|-------|---------|
| `resources.vpcs[]` | `id`, `cidr`, optional `name`, optional `tags` |
| `resources.subnets[]` | `id`, `vpcId`, `cidr`, `availabilityZone`, optional `name`, optional `tags` |
| `resources.routeTables[]` | optional; `id`, `vpcId`, optional `name`, optional `subnetIds`, optional `tags` |
| `resources.securityGroups[]` | `id`, `vpcId`, `name`, `description`, optional `tags` |

`name` sets the `Name` tag when `tags.Name` is absent. Apply always adds `awsbox:resource-id` from the fixture id (do not put that key in `tags`).

Unknown fields are rejected, including `secret`, `password`, `environment`, and `valueFrom`.

## Ids and tags

Apply sends tag `awsbox:resource-id` set to the fixture id. LocalEmu's start hook `localemu-patches/init/start.d/20-mirror-resource-ids.py` uses that tag as the VPC, subnet, route table, or security group id. Recreate the emulator after pulling the hook (`./bin/stackwrangler up` recreates when the compose spec changes; a container started from an older tree will not pin ids).

`describe-vpcs` / `describe-subnets` / `describe-route-tables` / `describe-security-groups` then return the fixture ids, CIDRs, and tags. A second `apply` of the same fixture is a no-op for matching shape and re-applies any missing tags / subnet associations.

Creates that omit the tag still get moto's random ids.

## What this is not

Real-account `mirror` (read-only Describe/List/Get, fixture written outside the repo, CloudTrail proof, the rest of the resource set) is [#220](https://github.com/kgz/awsl/issues/220). Dry-run is the list of intended reads only.

Smoke (throwaway LocalEmu, no shared stack, no real AWS):

```bash
./smokes/account/mirror-smoke.sh
./smokes/account/mirror-tags-smoke.sh
```
