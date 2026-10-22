# Security groups

EC2, ECS `awsvpc` tasks, and RDS instances on a VPC subnet enforce their security groups with iptables. A rule that names another security group allows the current members of that group and refuses everyone else. Changing a rule updates running workloads; they do not need to be recreated.

```bash
./bin/sg-enforcement-smoke.sh
```

After pulling, recreate LocalEmu so the patch is mounted:

```bash
./bin/awsbox up --force
```

Ingress and egress accept CIDRs, managed prefix lists, and security-group references. An empty prefix list or a security-group reference with no members does not become allow-all. ECS tasks with no `securityGroups` use the VPC default security group. RDS containers need `NET_ADMIN` so the same chains can be installed; Postgres images gain iptables on first start.

NLB client-IP preservation is [#236](https://github.com/kgz/awsl/issues/236) (needs #203). VPC Lambda security groups are [#237](https://github.com/kgz/awsl/issues/237). Console editing stays with [#146](https://github.com/kgz/awsl/issues/146).
