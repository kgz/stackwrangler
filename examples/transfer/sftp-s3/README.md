# Transfer Family SFTP → S3 (local)

```bash
./bin/awsbox up --force
./smokes/transfer/transfer-smoke.sh          # control plane
./smokes/transfer/transfer-key-smoke.sh      # SSH key put → S3 (+ Lambda)
```

Keep resources: `AWSBOX_TRANSFER_KEEP=1 ./smokes/transfer/transfer-key-smoke.sh`

See [docs/transfer.md](../../../docs/transfer.md).
