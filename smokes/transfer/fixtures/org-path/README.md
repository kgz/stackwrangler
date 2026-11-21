# Org-path smoke fixtures (#781)

Inline fixtures for `../org-path-smoke.sh` when `examples/org-path` / `examples/terraform/org-path` is missing.

Layout #780 should mirror so the smoke can prefer the example stack:

```
examples/org-path/   (or examples/terraform/org-path/)
  README.md          # apply / destroy against profile local
  lambda/handler.js  # ObjectCreated → processed/*.json
  # Transfer home bucket, ECS worker task, RDS ingest table
```

Assert S3 on LocalEmu `:4566` (path brain), not Seaweed `:8333` alone — see #162.
