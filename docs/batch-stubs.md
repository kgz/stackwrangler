# Batch / Beanstalk / App Runner / Autoscaling stubs (#83)

LocalEmu `SERVICES` includes `batch`, `elasticbeanstalk`, `apprunner`, `autoscaling`, `application-autoscaling` (see `docker-compose.yml`). Profile `local` points those APIs at `:4566`.

| Service | What works | What does not |
|---------|------------|---------------|
| Auto Scaling | create ASG, set desired capacity, describe | Treating launched instances as production ECS hosts beyond [#207](https://github.com/kgz/awsl/issues/207); authz [#334](https://github.com/kgz/awsl/issues/334); console [#337](https://github.com/kgz/awsl/issues/337) |
| Application Auto Scaling | register / describe scalable target | Policies driving real scale-out; authz [#334](https://github.com/kgz/awsl/issues/334) |
| Batch | compute environment + job queue create/describe | Job submit / run [#335](https://github.com/kgz/awsl/issues/335); authz [#334](https://github.com/kgz/awsl/issues/334); console [#337](https://github.com/kgz/awsl/issues/337) |
| Elastic Beanstalk | create/describe application, list solution stacks | Environment provision [#335](https://github.com/kgz/awsl/issues/335); authz [#334](https://github.com/kgz/awsl/issues/334); console [#337](https://github.com/kgz/awsl/issues/337) |
| App Runner | `list-services` / connections / ASC (empty stub) | `CreateService` and traffic [#335](https://github.com/kgz/awsl/issues/335); authz [#334](https://github.com/kgz/awsl/issues/334); console [#337](https://github.com/kgz/awsl/issues/337) |

## Smokes

```bash
./bin/stackwrangler up
./smokes/compute/autoscaling-smoke.sh
./smokes/compute/application-autoscaling-smoke.sh
./smokes/compute/batch-smoke.sh
./smokes/compute/elasticbeanstalk-smoke.sh
./smokes/compute/apprunner-smoke.sh
```

ASG CFN slice: `examples/serverless-v3-rest/slices/asg/`.
