# aws-endpoint-redirect

Transparent AWS endpoint redirect for tools that ignore `AWS_ENDPOINT_URL`
(notably Serverless Framework v4’s bundled AWS SDK v2).

Compose profile: `aws-redirect`. One dual-role container:

1. **dnsmasq** — `local=/…/` so AWS suffixes are never forwarded (A **and**
   AAAA; stops dualstack public IPv6), plus `address=/…/<proxy-ipv4>` for A
   → this TLS edge. Everything else → upstream DNS. Query log at
   `/var/log/aws-redirect-dnsmasq.log`.
2. **TLS edge** (`:443`) — dynamic leaf cert per SNI, signed by a local CA
   under `.awsbox/aws-redirect/`, HTTP forward to LocalEmu `:4566` with the
   client `Host` header kept. Request and response are piped **concurrently**
   so `Expect: 100-continue` (S3 PutObject ≳1 MB) does not deadlock.

Compose healthcheck (`healthcheck.sh`) requires DNS **and** a TLS `:443`
handshake — DNS alone is not ready (TLS can exit while dnsmasq stays up).

Use via `./bin/stackwrangler sls -- …` (see `docs/serverless-awsbox.md`).
