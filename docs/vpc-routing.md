# VPC routing

Subnet route tables control EC2 egress, and ECS `awsvpc` tasks get the same rules. A private subnet whose table has no `0.0.0.0/0` route cannot reach a public host — including images that run as a non-root user (route sync execs as root in the container netns). A peering route (including a non-RFC1918 CIDR) reaches the other VPC, and removing that route breaks that direction. A `0.0.0.0/0` route to a NAT gateway or internet gateway restores egress.

ECS tasks still reach the injected `AWS_ENDPOINT_URL` (LocalEmu’s compose-network IP on `:4566`) without a default route: the task joins that network and the route filter allows the gateway `/32`. Host publish stays loopback-only for the CLI.

```bash
./bin/vpc-routing-smoke.sh
```

After pulling, recreate LocalEmu so the patch is mounted:

```bash
./bin/awsbox up --force
```

Workloads attach to the Docker network of the subnet's VPC (`localemu-vpc-<vpc-id>`). EC2 still publishes ports on `localemu-pubport-br`; without a default route that bridge's default route is removed and other destinations are dropped. Peering and NAT attachments follow the route table, not the mere existence of the connection or gateway.

Lambda `VpcConfig` is attached to that same VPC network. Its egress is not filtered. Gateway endpoint prefix lists, ECS `bridge`/`host` modes, per-subnet networks, and replay after a container restart are [#230](https://github.com/kgz/awsl/issues/230). Console route tables stay with [#146](https://github.com/kgz/awsl/issues/146).
