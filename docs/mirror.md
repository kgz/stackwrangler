# Account mirror (`awsl mirror` / `awsl apply`)

Synthetic topology fixtures for the local emulator. This pass applies a VPC, subnet, and security group. Reading a real account is [#220](https://github.com/kgz/awsl/issues/220) — `mirror` does not call AWS.

## Commands

```bash
./bin/awsl mirror dry-run
./bin/awsl apply testdata/mirror/synthetic-vpc.json
# same entry points:
./bin/awsbox mirror dry-run
./bin/awsbox apply testdata/mirror/synthetic-vpc.json
```

`mirror` without `dry-run` exits 2. It does not call AWS and does not write a fixture.

`mirror --out <dir>` checks the path, then still refuses to read:

- A path inside this repo is refused unless `git check-ignore` matches it.
- A path outside the repo, or a gitignored path, is allowed as a destination but nothing is written yet.

`mirror dry-run` prints the read APIs a later pass would call, and the calls it will not make (`GetSecretValue`, `GetParameter`, task-definition environment, Lambda environment). No client calls go out.

`apply` creates resources on `AWSBOX_IAM_ENDPOINT` (default `http://127.0.0.1:4566`). The host must be loopback (`127.0.0.1`, `localhost`, `::1`, or `*.localhost`). Any other endpoint, including real AWS, is refused before the CLI runs.

## Fixture

Schema: [testdata/mirror/schema.json](../testdata/mirror/schema.json) (`awsl.mirror/v1`).

Example (no account data, no secrets): [testdata/mirror/synthetic-vpc.json](../testdata/mirror/synthetic-vpc.json).

| Field | Meaning |
|-------|---------|
| `resources.vpcs[]` | `id`, `cidr`, optional `name` |
| `resources.subnets[]` | `id`, `vpcId`, `cidr`, `availabilityZone`, optional `name` |
| `resources.securityGroups[]` | `id`, `vpcId`, `name`, `description` |

Unknown fields are rejected, including `secret`, `password`, `environment`, and `valueFrom`.

## Ids

Apply sends tag `awsbox:resource-id` set to the fixture id. LocalEmu's start hook `localemu-patches/init/start.d/20-mirror-resource-ids.py` uses that tag as the VPC, subnet, or security group id. Recreate the emulator after pulling the hook (`./bin/awsbox up` recreates when the compose spec changes; a container started from an older tree will not pin ids).

`describe-vpcs` / `describe-subnets` / `describe-security-groups` then return the fixture ids and CIDRs. A second `apply` of the same fixture is a no-op when those already match.

Creates that omit the tag still get moto's random ids.

## What this is not

Real-account `mirror` (read-only Describe/List/Get, fixture written outside the repo, CloudTrail proof, the rest of the resource set) is [#220](https://github.com/kgz/awsl/issues/220). Dry-run is the list of intended reads only.

Smoke (throwaway LocalEmu, no shared stack, no real AWS):

```bash
./bin/mirror-smoke.sh
```
