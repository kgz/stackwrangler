# Slice: acm (#74)

Request a DNS-validated ACM certificate for `api.example.test`, then attach its ARN to an API Gateway custom domain and an ALB HTTPS listener (learning path for serverless-domain-manager + HTTPS ALB).

**Smoke:** `./smokes/security/acm-smoke.sh` (CLI against LocalEmu). Control-plane store/describe only — TLS handshake presenting the ACM keypair is [#242](https://github.com/kgz/awsl/issues/242).

Parent fixture `examples/serverless-v3-rest/` is owned by #185; this slice runs alone via the smoke.
