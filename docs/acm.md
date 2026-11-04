# ACM certificates (local)

LocalEmu `acm` on `:4566` (`SERVICES` includes `acm`; profile `local` has `acm` → IAM endpoint).

**Control plane for learning paths.** Request / import / describe / list work. Certificate ARNs are accepted by API Gateway custom domains and stored on ELBv2 HTTPS/TLS listeners. **TLS handshake does not present the ACM keypair** — listeners still terminate with LocalEmu’s default cert ([#242](https://github.com/kgz/awsl/issues/242)).

## Smokes

```bash
./bin/stackwrangler up --force
./bin/acm-smoke.sh
```

Happy: request DNS-validated cert for `api.example.test`, describe/list, import PEM, create API custom domain with the ARN, create ALB HTTPS listener that stores the ARN.  
Sad: deny-user `acm:RequestCertificate` → AccessDenied.

## Slice

`examples/serverless-v3-rest/slices/acm/` — CFN shape (`AWS::CertificateManager::Certificate`, API domain, ALB HTTPS listener). Smoke applies the same shape via CLI.

## Limits

| Area | Behaviour |
|------|-----------|
| Request / import / describe / list | Working (moto) |
| API GW `create-domain-name` regional cert ARN | Working |
| ELBv2 listener `Certificates[].CertificateArn` | Stored / described |
| TLS handshake with ACM keypair | **Not implemented** — [#242](https://github.com/kgz/awsl/issues/242) |
| Console | None → [#333](https://github.com/kgz/awsl/issues/333) |
| DNS validation automation | Emulator accepts request; no real DNS challenge |
