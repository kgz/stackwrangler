# LocalEmu gaps (from explore) — implement against these

Digest: `localemu/localemu@sha256:86a84bf21e3c0cf2cb695bdd890bce642e8e3d852c41f46d7aa8123551cee10b`

## Already present
- `elbv2/provider.py` + `listener_router.py` — HTTP/HTTPS only; ephemeral bind port; instance targets → `127.0.0.1`
- `ec2/docker/vpc_network.py` — per-VPC bridge; IGW toggles `--internal`
- `container_routing.py` — peering `/32` between EC2 containers
- `nat_gateway.py` — NAT exists but attaches **all** VPC containers (ignores route tables)
- `instance_routes.py` — only `InstanceId` route targets
- `AddressIndex` + `SubnetAllocator` + `sg_iptables.py` (EC2). #205 extends the same apply to ECS awsvpc and RDS (`localemu-patches/sg_enforcement.py`)
- `vpc_dns.py` — drops `AmazonProvidedDNS` (no resolver)

## Ship order
#204 → #205 → #203 → #206

## #204 first slice
1. Pin ECS awsvpc / EC2 subnet IPs; track subnet_id
2. In workload netns: drop egress unless route table allows (igw/nat/pcx both sides)
3. Peering + NAT honour subnet route tables (`DeleteRoute` breaks reachability)
4. Smoke: `bin/vpc-routing-smoke.sh`

## #205
1. EC2 `sg_iptables` + `AddressIndex` stay the enforcer
2. ECS awsvpc and RDS register an ENI and get the same chains; authorize/revoke reapplies without recreate
3. Prefix list entries expand to CIDRs at apply time (`ModifyManagedPrefixList` reapplies)
4. Smoke: `bin/sg-enforcement-smoke.sh`
5. NLB client IP [#236](https://github.com/kgz/awsl/issues/236); VPC Lambda [#237](https://github.com/kgz/awsl/issues/237)

## Shared touchpoints
- `localemu-patches/ecs_task_manager.py`
- `ec2/docker/{vpc_network,instance_routes,nat_gateway,address_index,sg_iptables}.py`
- compose `SERVICES` += `elbv2` for #203
