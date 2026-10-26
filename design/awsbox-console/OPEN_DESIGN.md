# Open Design — awsbox-console

- Project id: `2ce89424-6266-4cc3-a273-3b68c3049183`
- Name: `awsbox-console`
- On disk: this folder (imported with `baseDir` — edits here are the OD project)
- Theme: `design/awsbox/` (grey rose) — required for new screens
- Skills: prefer `web-clone` for real AWS console screens; `frontend-design` for craft
- Role: awsbox console mocks. Not the runtime product UI.

Board: web UI tickets use status **designing** while OD runs (`./bin/od-design-run.sh --issue <n>` sets it). Move to **in-progress** only after mocks land here.

Dead controls: not wired yet → `disabled` with `title="To implement"`. Will never ship → omit. Never leave an enabled button/link that does nothing (including toast-only).

Start a run (shows in OD UI):

```bash
./bin/od-design-run.sh --issue <n> "Design …"
```

Visual refs: `refs/`. Paint with grey rose, not AWS orange / sky blue / smile.

Daemon must mount this repo (already in `~/tools/open-design/deploy/docker-compose.wsl.yml`):

```
/home/mat/projects/awsl:/home/mat/projects/awsl:rw
```
