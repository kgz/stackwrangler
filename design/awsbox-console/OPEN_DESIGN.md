# Open Design — awsbox-console

- Project id: `2ce89424-6266-4cc3-a273-3b68c3049183`
- Name: `awsbox-console`
- Conversation: `eb1c88fa-e9f5-4667-829a-9044c48f472c`
- On disk: this folder (imported with `baseDir` — edits here are the OD project)
- Skill: `frontend-design`
- Role: AWS-feel console mocks (S3 browser, Lambda, frame chrome). Not the runtime product UI.

Start a run (shows in OD UI):

```bash
./bin/od-design-run.sh --issue <n> "Design …"
```

Stub: `index.html` — replace via OD when building console screens (#4 / #5).

Daemon must mount this repo (already in `~/tools/open-design/deploy/docker-compose.wsl.yml`):

```
/home/mat/projects/awsl:/home/mat/projects/awsl:rw
```
