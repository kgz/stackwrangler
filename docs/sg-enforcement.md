# Security groups

EC2, ECS `awsvpc` tasks, RDS instances, and VPC Lambdas on a VPC subnet enforce their security groups with iptables. A rule that names another security group allows the current members of that group and refuses everyone else. Changing a rule updates running workloads; they do not need to be recreated.

```bash
./bin/sg-enforcement-smoke.sh
```

After pulling, recreate LocalEmu so the patch is mounted:

```bash
./bin/awsbox up --force
```

Ingress and egress accept CIDRs, managed prefix lists, and security-group references. An empty prefix list or a security-group reference with no members does not become allow-all. ECS tasks with no `securityGroups` use the VPC default security group. RDS containers need `NET_ADMIN` so the same chains can be installed; Postgres images gain iptables on first start. VPC Lambda (and any workload image without iptables) programs `SG_IN` / `SG_OUT` through the alpine netns sidecar used for VPC routes — the runtime image is never apt/yum'd ([#237](https://github.com/kgz/awsl/issues/237), [#369](https://github.com/kgz/awsl/issues/369)). LocalEmu’s invoke path into the runtime is allowed past `SG_IN` (same idea as AWS not putting the Lambda service control plane through the ENI security group).

Images without iptables that previously reached package mirrors via the default docker bridge can no longer install it on private awsvpc tasks ([#271](https://github.com/kgz/awsl/issues/271)); that gap is [#282](https://github.com/kgz/awsl/issues/282) (sidecar apply in `sg_enforcement` covers the filter chains when iptables is already missing). NLB client-IP preservation is [#236](https://github.com/kgz/awsl/issues/236) (needs #203). Console editing stays with [#146](https://github.com/kgz/awsl/issues/146).
