# Lambda VPC → host service

Function with `VpcConfig` reaches a service on the Docker host via `STACKWRANGLER_LAMBDA_DOCKER_FLAGS` / `AWSBOX_LAMBDA_DOCKER_FLAGS` host maps. Unmapped names fail. Functions **without** `VpcConfig` do not get those maps ([#187](https://github.com/kgz/stackwrangler/issues/187)).

**Status:** working · [lambda-vpc.md](https://github.com/kgz/stackwrangler/blob/main/docs/lambda-vpc.md)

## Sequence

1. Place Lambda in the stack VPC / subnet shape the smoke uses.
2. Invoke; handler reaches the host-mapped dependency.
3. Sad: unmapped hostname; non-VPC function cannot resolve the mapped name.

## Prove it

```bash
./smokes/lambda/lambda-vpc-smoke.sh
```
