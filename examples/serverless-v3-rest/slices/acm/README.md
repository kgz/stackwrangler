# Slice: acm (#74)

Request a DNS-validated ACM certificate for `api.example.test`, then attach its ARN to an API Gateway custom domain and an ALB HTTPS listener (learning path for serverless-domain-manager + HTTPS ALB).

**Smoke:** `./smokes/security/acm-smoke.sh` (CLI against LocalEmu). TLS handshake presenting the ACM keypair: `./smokes/networking/elbv2-smoke.sh`.

Parent fixture `examples/serverless-v3-rest/` is owned by #185; this slice runs alone via the smoke.
