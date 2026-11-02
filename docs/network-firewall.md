# Network Firewall + Firewall Manager (local)

LocalEmu `network-firewall` (stub_providers for policy/rule-group; moto fallthrough for firewall create/list) and `fms` (stub_providers) on `:4566`.

**Control plane only.** Creating rule groups, firewall policies, and FMS org policies stores API state; **packets are not filtered** and FMS does **not** push protections into member accounts.

## Smokes

```bash
./bin/awsbox up --force   # after SERVICES / start.d change
./bin/network-firewall-fms-smoke.sh
```

`AWSBOX_NFW_KEEP=1` (or `KEEP=1`) skips teardown while iterating.

## Profile

`./bin/awsbox-profile write --force` sends `network-firewall` / `fms` to the LocalEmu endpoint.

## Limits

| Area | Behaviour |
|------|-----------|
| Rule group create / describe / list / delete | Working (stub_providers) |
| Firewall policy create / describe / list / delete | Working (stub_providers) |
| Firewall create / describe / list | moto (needs a policy ARN) |
| Packet filtering / Suricata eval | **Not implemented** → [#441](https://github.com/kgz/stackwrangler/issues/441) |
| FMS Put/Get/List/Delete policy | Working (in-memory stub) |
| FMS org enforcement / account fan-out | **Not implemented** → [#442](https://github.com/kgz/stackwrangler/issues/442) |
| Network Firewall console | None → [#438](https://github.com/kgz/stackwrangler/issues/438) |
| Firewall Manager console | None → [#439](https://github.com/kgz/stackwrangler/issues/439) |
| Authz (deny-user) | **Not smoked** → [#440](https://github.com/kgz/stackwrangler/issues/440) |
