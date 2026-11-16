# ecr-hostname-proxy

TLS edge so `docker login` / `push` / `pull` work against the ECR
`repositoryUri` hostname (`<account>.dkr.ecr.<region>.amazonaws.com`) without
retagging to `127.0.0.1:5000` (#218).

TLS implementation is **shared**: `../aws-endpoint-redirect/tls_proxy.py`
(entrypoint maps `ECR_REGISTRY_URL` → `LOCALEMU_URL`). Do not fork that file.

Compose service `ecr-hostname` listens on **container** `:443` with a fixed
bridge IP (default `10.254.218.10`, host `.10` of `STACKWRANGLER_ECR_HOSTNAME_SUBNET`) so host `:443` can stay occupied.
Before v0.0.8 the default was `172.31.218.10`; after upgrading, re-run `./bin/stackwrangler-hosts ecr-apply`
so `/etc/hosts` points at the new IP (`up` prints this hint while `ecr-check` fails). Dynamic
SNI leafs are signed by `.awsbox/ecr-hostname/ca.crt`.

Wire-up (also `./bin/stackwrangler-hosts ecr-apply`):

1. `/etc/hosts` → fixed IP for the URI hostname
2. `/etc/docker/certs.d/<URI_HOST>/ca.crt` ← CA (no daemon restart)

Plain `127.0.0.1:5000` push/pull remains for ECS rewrite and older smokes.
