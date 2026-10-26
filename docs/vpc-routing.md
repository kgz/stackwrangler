# VPC routing

Subnet route tables control EC2 egress, ECS `awsvpc` / `bridge` tasks, and VPC Lambda. A private subnet whose table has no `0.0.0.0/0` route cannot reach a public host — including images that run as a non-root user (route sync execs as root in the container netns). A peering route (including a non-RFC1918 CIDR) reaches the other VPC, and removing that route breaks that direction. A `0.0.0.0/0` route to a NAT gateway or internet gateway restores egress.

Gateway endpoints (S3 / DynamoDB) install a prefix-list route to `vpce-*`. Private workloads may reach those prefix-list destinations only when that route exists; packets are DNATed to the LocalEmu gateway so the service call succeeds. Without the route, the prefix-list CIDRs are dropped.

ECS tasks still reach the injected `AWS_ENDPOINT_URL` (LocalEmu’s compose-network IP on `:4566`) without a default route: the task joins that network and the route filter allows the gateway `/32`. Host publish stays loopback-only for the CLI. Mapped `host.docker.internal` stays allowed so `./bin/lambda-vpc-smoke.sh` keeps working.

Route rules are re-applied after `docker start` (container restart / ECS resume). VPC Lambda containers stay **non-privileged**: iptables/route sync runs in a privileged alpine netns sidecar (`localemu/awsbox-rt`, `--network container:<workload>`). ECS `bridge` tasks keep docker0 for host ports and also join `localemu-vpc-<vpc-id>` (`./bin/vpc-egress-bridge-check.sh`).

```bash
./bin/vpc-routing-smoke.sh          # EC2 private / peering / NAT (#204)
./bin/vpc-egress-smoke.sh           # Lambda + gateway endpoints + bridge attach (#230)
```

After pulling, recreate LocalEmu so the patch is mounted:

```bash
./bin/awsbox up --force
```

Workloads attach to the Docker network of the subnet's VPC (`localemu-vpc-<vpc-id>`). ECS `awsvpc` tasks attach **only** to that VPC network (not the default docker bridge); `host.docker.internal` maps to the VPC bridge gateway so host reachability is explicit ([#271](https://github.com/kgz/awsl/issues/271)). ECS `bridge` tasks stay on docker0 for host ports and also join the container-instance subnet's VPC network so the same route filter applies. EC2 still publishes ports on `localemu-pubport-br`; without a default route that bridge's default route is removed and other destinations are dropped. Peering and NAT attachments follow the route table, not the mere existence of the connection or gateway.

ECS `awsvpc` tasks pin an address from the subnet CIDR via `SubnetAllocator` (same as EC2/RDS). `DescribeTasks` attachment `privateIPv4Address` is that container address, so ip-type target registration from `describe-tasks` reaches the task (`./bin/apigw-nlb-ecs-smoke.sh`, [#268](https://github.com/kgz/awsl/issues/268)).

Console route tables stay with [#146](https://github.com/kgz/awsl/issues/146).
