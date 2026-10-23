# SQS (local)

LocalEmu `sqs` on `:4566` (`SERVICES` includes `sqs`).

```bash
./bin/awsbox up --force   # after enabling sqs in compose
./bin/sqs-smoke.sh
./bin/sqs-authz-smoke.sh
```

| Area | Status |
|------|--------|
| create / send / receive / delete | Working (smoke) |
| Deny-user SendMessage | Working (`sqs-authz-smoke.sh`) |
| SNS → SQS delivery respects queue policy (`aws:SourceArn`) | Working (`sns-sqs-fanout-smoke.sh`) |
| Console | Not wired — Debt from #64 |
