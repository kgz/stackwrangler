# Transfer Family SFTP → S3 (local)

```bash
./bin/awsbox up --force
./bin/transfer-smoke.sh          # control plane
./bin/transfer-key-smoke.sh      # SSH key put → S3 (+ Lambda)
```

Keep resources: `AWSBOX_TRANSFER_KEEP=1 ./bin/transfer-key-smoke.sh`

See [docs/transfer.md](../../../docs/transfer.md).
