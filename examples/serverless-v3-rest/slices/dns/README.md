# slice: dns

Public Route 53 hosted zone + records shaped like a Serverless domain plugin
after deploy: zone `example.test`, A-alias / CNAME for the API hostname.

- `serverless.yml` — `AWS::Route53::HostedZone` + `RecordSet` resources a
  domain plugin would create.
- `template.yaml` — same shape for the smoke (no Serverless Framework required).

```bash
./bin/awsbox up
./bin/route53-smoke.sh
```

Smoke (isolated compose ports by default): create public zone, UPSERT A +
A-alias + CNAME, `list-resource-record-sets`, `dig @127.0.0.1` inside the
emulator, private zone create, profile `local` list, deny `ListHostedZones`.

Private zone **resolution** from VPC workloads: [docs/r53-private.md](../../../../docs/r53-private.md)
· `./bin/r53-private-smoke.sh`. Overview: [docs/r53.md](../../../../docs/r53.md).

Parent fixture (#185) may land separately; this slice stands alone.
