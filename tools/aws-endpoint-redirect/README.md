# aws-endpoint-redirect

Transparent AWS endpoint redirect for tools that ignore `AWS_ENDPOINT_URL`
(notably Serverless Framework v4’s bundled AWS SDK v2).

Compose profile: `aws-redirect`. One dual-role container:

1. **dnsmasq** — `*.amazonaws.com`, `*.amazonaws.com.cn`, `*.api.aws`,
   `aws.amazon.com` → this container’s IP; everything else → upstream DNS.
   Query log at `/var/log/aws-redirect-dnsmasq.log` (fail-closed: AWS names
   never resolve to public IPs).
2. **TLS edge** (`:443`) — dynamic leaf cert per SNI, signed by a local CA
   under `.awsbox/aws-redirect/`, HTTP forward to LocalEmu `:4566` with the
   client `Host` header kept.

Compose healthcheck (`healthcheck.sh`) requires DNS **and** a TLS `:443`
handshake — DNS alone is not ready (TLS can exit while dnsmasq stays up).

Use via `./bin/stackwrangler sls -- …` (see `docs/serverless-awsbox.md`).
