# Slice: transfer-in (#141)

AWS-shaped inbound Transfer Family: service-managed SFTP user with an SSH
public key, home on S3, ObjectCreated Lambda on `inbox/`.

Parent fixture: [`examples/serverless-v3-rest/`](../../) ([#185](https://github.com/kgz/awsl/issues/185)).
This slice is standalone — smoke does not require Serverless CLI.

```bash
./bin/awsbox up --force
./bin/transfer-key-smoke.sh
```

See [docs/transfer.md](../../../../docs/transfer.md).
