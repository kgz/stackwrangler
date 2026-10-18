# Transfer Family → S3 (LocalEmu)

API-level SFTP server + managed user with an S3 home directory.

```bash
# from repo root
./bin/awsbox up --force
./bin/transfer-smoke.sh
```

Keep resources: `AWSBOX_TRANSFER_KEEP=1 ./bin/transfer-smoke.sh`

See [docs/transfer.md](../../../docs/transfer.md) for LocalEmu limits (no real SFTP data plane expected).
