# Security groups

EC2, ECS `awsvpc` tasks, RDS instances, and VPC Lambdas on a VPC subnet enforce their security groups with iptables. A rule that names another security group allows the current members of that group and refuses everyone else. Changing a rule updates running workloads; they do not need to be recreated.

```bash
./smokes/networking/sg-enforcement-smoke.sh
```

After pulling, recreate LocalEmu so the patch is mounted:

```bash
./bin/stackwrangler up --force
```

Ingress and egress accept CIDRs, managed prefix lists, and security-group references. An empty prefix list or a security-group reference with no members does not become allow-all. ECS tasks with no `securityGroups` use the VPC default security group. RDS containers need `NET_ADMIN` so the same chains can be installed; Postgres images gain iptables on first start. VPC Lambda (and any workload image without iptables) programs `SG_IN` / `SG_OUT` through the alpine netns sidecar used for VPC routes — the runtime image is never apt/yum'd ([#237](https://github.com/kgz/awsl/issues/237), [#369](https://github.com/kgz/awsl/issues/369)). LocalEmu’s invoke path into the runtime is allowed past `SG_IN` (same idea as AWS not putting the Lambda service control plane through the ENI security group).

ECS task-role credentials stay reachable under a tight egress SG: `169.254.170.2` (and the post-DNAT LocalEmu creds port) are exempt from `SG_OUT`, matching AWS link-local behaviour. Injected `AWS_ENDPOINT_URL` traffic is accepted only when the task’s VPC has a VPC endpoint and the SG would allow HTTPS egress that would reach an interface ENI or gateway prefix list — without a matching endpoint the call is dropped ([#686](https://github.com/kgz/stackwrangler/issues/686); `./smokes/compute/ecs-sg-creds-endpoint-smoke.sh`).

Images without iptables that previously reached package mirrors via the default docker bridge can no longer install it on private awsvpc tasks ([#271](https://github.com/kgz/awsl/issues/271)); that gap is [#282](https://github.com/kgz/awsl/issues/282) (sidecar apply in `sg_enforcement` covers the filter chains when iptables is already missing). NLB client-IP preservation is [#236](https://github.com/kgz/awsl/issues/236) (needs #203). Console editing stays with [#146](https://github.com/kgz/awsl/issues/146).
