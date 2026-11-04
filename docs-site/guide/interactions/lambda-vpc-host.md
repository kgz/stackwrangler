# Lambda VPC → host service

Function in a VPC reaches a service on the Docker host via the local network mapping. Unmapped names fail. Full isolation vs real AWS VPC is still partial.

**Status:** partial · Gaps: [#187](https://github.com/kgz/stackwrangler/issues/187) · [lambda-vpc.md](https://github.com/kgz/stackwrangler/blob/main/docs/lambda-vpc.md)

## Sequence

1. Place Lambda in the stack VPC / subnet shape the smoke uses.
2. Invoke; handler reaches the host-mapped dependency.
3. Sad: unmapped hostname.

## Prove it

```bash
./smokes/lambda/lambda-vpc-smoke.sh
```
