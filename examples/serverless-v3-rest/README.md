# serverless-v3-rest (replication fixture)

Dummy [Serverless Framework v3](https://www.serverless.com/) project slices for
awsbox high-focus tickets. Parent stack: [#185](https://github.com/kgz/awsl/issues/185)
(may land separately). Each `slices/<name>/` stands alone with its own smoke.

| Slice | Ticket | Smoke |
|-------|--------|-------|
| `dns` | [#56](https://github.com/kgz/awsl/issues/56) | `./bin/route53-smoke.sh` |

```bash
./bin/awsbox up
./bin/route53-smoke.sh
```

See [docs/r53.md](../../docs/r53.md).
