# ecr-hostname-proxy

TLS edge so `docker login` / `push` / `pull` work against the ECR
`repositoryUri` hostname (`<account>.dkr.ecr.<region>.amazonaws.com`) without
retagging to `127.0.0.1:5000` (#218).

Compose service `ecr-hostname` listens on **container** `:443` with a fixed
bridge IP (default `172.31.218.10`) so host `:443` can stay occupied. Dynamic
SNI leafs are signed by `.awsbox/ecr-hostname/ca.crt`.

Wire-up (also `./bin/stackwrangler-hosts ecr-apply`):

1. `/etc/hosts` → fixed IP for the URI hostname
2. `/etc/docker/certs.d/<URI_HOST>/ca.crt` ← CA (no daemon restart)

Plain `127.0.0.1:5000` push/pull remains for ECS rewrite and older smokes.
