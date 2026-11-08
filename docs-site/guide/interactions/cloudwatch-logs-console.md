# CloudWatch Logs console create / detail

Console **Create log group** (`/logs/create`) calls `CreateLogGroup`. Group detail lists streams and can search events; stream detail shows `GetLogEvents` / filter results.

**Status:** partial · Console create + group/stream detail: [#352](https://github.com/kgz/stackwrangler/issues/352) (PR [#604](https://github.com/kgz/stackwrangler/pull/604)). API path smoked on main.

## Sequence

1. Open `/logs` → **Create log group** (`/logs/create`).
2. Submit name (+ optional retention) → LocalEmu `CreateLogGroup` → detail at `/logs/log-groups/:name`.
3. **Log streams** tab lists streams; open a stream for events, or **Search log group** with a filter pattern.
4. CLI: `logs create-log-group` / `put-log-events` / `filter-log-events` via `./smokes/logs/logs-smoke.sh`.

## Prove it

```bash
./smokes/logs/logs-smoke.sh
./smokes/logs/logs-authz-smoke.sh
# console create + detail (needs #352 pages)
cd console && yarn playwright test e2e/logs-create-detail.spec.ts
```

Matrix: [smoke-matrix](https://github.com/kgz/stackwrangler/blob/main/docs/smoke-matrix.md) · Logs.

## Console

![Log groups](/assets/console/logs-log-groups.png)

![Create log group](/assets/console/logs-create-log-group.png)

![Log group detail](/assets/console/logs-log-group-detail.png)

![Log stream events](/assets/console/logs-log-stream-events.png)

Shots captured against the #352 console surface. List re-capture runs on main; create/detail/stream capture tests stay skipped until #604 merges — then unskip and seed `/stackwrangler/docs-608` + stream `docs-stream`.
