# slice: schedule

Scheduled cleanup Lambda: an EventBridge rule (`rate(1 minute)`, explicit name)
invokes a Lambda that sweeps expired items from a DynamoDB table.

- `serverless.yml` — what the real stack declares (`events: - schedule`).
- `template.yaml` — the CloudFormation Serverless Framework generates for it
  (`AWS::Events::Rule` + `AWS::Lambda::Permission` for `events.amazonaws.com`).
  The smoke deploys this one; Serverless Framework itself is not required.
- `src/index.js` — stub sweeper. Logs `sweep-tick` per invocation.

```bash
./bin/awsbox up
./smokes/messaging/events-schedule-smoke.sh
```

Smoke asserts: at least 2 invocations in 3 minutes, none after
`disable-rule`; a rule without the invoke permission never fires the target.

Emulator behaviour comes from `localemu-patches/init/start.d/20-events-schedule.py`
(disable/delete stop the job; Lambda targets need an `events.amazonaws.com`
grant). Recreate the stack after pulling it: `./bin/awsbox up`.

Timings: `AWSBOX_SCHEDULE_WINDOW` (default 180s) and `AWSBOX_SCHEDULE_QUIET`
(default 90s).

Known gaps: [#317](https://github.com/kgz/awsl/issues/317) (non-wildcard cron,
`rate(N minutes)` cadence, enable after create-disabled).
