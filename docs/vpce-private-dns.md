# VPC Interface endpoint private DNS

Interface endpoints created with `PrivateDnsEnabled` answer the regional service hostname from workloads in that VPC. Another VPC does not get that private answer.

`./bin/awsbox up --force` after pulling so the resolver (`init/boot.d`) and EC2/ECS/Lambda `--dns` hooks load. The resolver process needs port 53 (`NET_BIND_SERVICE` before the gateway drops it).

## What resolves

From a container whose `--dns` is this emulator's address on that VPC network:

| Service name | Hostname |
|--------------|----------|
| `com.amazonaws.<region>.sts` | `sts.<region>.amazonaws.com` |
| `com.amazonaws.<region>.logs` | `logs.<region>.amazonaws.com` |
| `com.amazonaws.<region>.ssm` | `ssm.<region>.amazonaws.com` |
| `com.amazonaws.<region>.ecs` | `ecs.<region>.amazonaws.com` |
| `com.amazonaws.<region>.ecr.api` | `api.ecr.<region>.amazonaws.com` |
| `com.amazonaws.<region>.ecr.dkr` | `dkr.ecr.<region>.amazonaws.com` (and `*.dkr.ecr…`) |

The A record is the Interface endpoint proxy IP on the VPC Docker network. That proxy forwards TCP 443/4566 to LocalEmu, so `http://<hostname>:4566/` from the workload reaches awsbox.

EC2, ECS `awsvpc`, and Lambda `VpcConfig` get the resolver via `--dns` (ECS also rewrites `/etc/resolv.conf` after attach).

## Smoke

```bash
./bin/vpce-private-dns-smoke.sh
```

Uses host port `24568` (`AWSBOX_VPCE_HOST_PORT`) so it does not take over a stack already on `:4566`. Proves resolution with ECS `awsvpc` tasks (getent + HTTP to `:4566` through the endpoint proxy).

## Limits

- Private DNS is answered by the awsbox resolver, not a real Route 53 private hosted zone API object ([#206](https://github.com/kgz/awsl/issues/206) covers PHZ).
- Gateway endpoints stay with [#230](https://github.com/kgz/awsl/issues/230).
- Console VPC endpoints stay with [#146](https://github.com/kgz/awsl/issues/146).
