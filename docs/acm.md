# ACM certificates (local)

LocalEmu `acm` on `:4566` (`SERVICES` includes `acm`; profile `local` has `acm` → IAM endpoint).

**Control plane for learning paths.** Request / import / describe / list work. Certificate ARNs are accepted by API Gateway custom domains and by ELBv2 HTTPS/TLS listeners, which present the attached ACM keypair on the TLS handshake. `ModifyListener` reloads live handshake material when the default cert changes ([#594](https://github.com/kgz/awsl/issues/594)); `AddListenerCertificates` is SNI-only unless it establishes the first default on a cert-less listener.

## Smokes

```bash
./bin/stackwrangler up --force
./smokes/security/acm-smoke.sh
```

Happy: request DNS-validated cert for `api.example.test`, describe/list, import PEM, create API custom domain with the ARN, create ALB HTTPS listener that stores the ARN. TLS handshake with the ACM keypair is covered by `./smokes/networking/elbv2-smoke.sh`.  
Sad: deny-user `acm:RequestCertificate` → AccessDenied.

## Slice

`examples/serverless-v3-rest/slices/acm/` — CFN shape (`AWS::CertificateManager::Certificate`, API domain, ALB HTTPS listener). Smoke applies the same shape via CLI.

## Limits

| Area | Behaviour |
|------|-----------|
| Request / import / describe / list | Working (moto) |
| API GW `create-domain-name` regional cert ARN | Working |
| ELBv2 listener `Certificates[].CertificateArn` | Stored / described; handshake presents the keypair |
| TLS handshake with ACM keypair | Working (`elbv2-smoke.sh`); create-time [#242](https://github.com/kgz/awsl/issues/242); ModifyListener / first-default Add reload for TLS NLB [#594](https://github.com/kgz/awsl/issues/594) and HTTPS ALB [#629](https://github.com/kgz/awsl/issues/629) |
| Console | None → [#333](https://github.com/kgz/awsl/issues/333) |
| DNS validation automation | Emulator accepts request; no real DNS challenge |
