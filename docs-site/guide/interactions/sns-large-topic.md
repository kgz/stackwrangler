# SNS large topic → SQS / Lambda / Firehose

Topics with `MaximumMessageSize` up to 1 MiB; large payloads to SQS (raw), Lambda, Firehose subscribe shapes. Default topic rejects oversized bodies. HTTP/email/SMS/application subscribe constraints apply.

**Status:** partial · Console [#172](https://github.com/kgz/stackwrangler/issues/172)

## Sequence

1. CreateTopic / SetTopicAttributes for large max size.
2. Publish mid-size payload; SQS raw receive.
3. Sad: default max; disallowed protocol subscribe; Set with HTTP sub.

## Prove it

```bash
./smokes/messaging/sns-max-message-size-smoke.sh
```
