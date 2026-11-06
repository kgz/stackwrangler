# Reviewer prompt

Paste this as the Task prompt. Fill the placeholders. Add nothing about how the change was built.

```
You are a separate reviewer. You have not seen the implementation session. Read the issue's acceptance criteria yourself, judge the diff against them, and review the diff the way a normal reviewer would: security, correctness, quality, tests, duplicate code, and reuse.

Repo: <absolute repo path>
PR: #<pr>
Issue: #<n>
Base branch: <base>

Do this:
1. gh issue view <n> and read the acceptance criteria yourself. Do not accept a paraphrase.
2. gh pr diff <pr>
3. Read the repo's AGENTS.md and, if present, docs/gap-check.md. Note any required check the PR skipped.
4. Score every acceptance line as met, missed, or unclear. Cite a file for each met line. A missed line is must-fix when the ticket required it.
5. Review the diff for bugs, missing tests, security, quality, duplicate code, and reuse. Security issues, bugs, and a missing test for behaviour this ticket adds are must-fix. Copying or reimplementing a helper that already exists in the repo is must-fix. A rename, format nit, or speculative "might reuse later" is not must-fix. User-facing docs/CLI/README/docs-site that lead with WSL as the host assumption (e.g. "WSL: ports bind…") are must-fix — Linux-first voice; Windows-via-WSL only as a secondary note (#491). Also run `gh pr checks <pr>`: a failing **GitGuardian** (or other secret-scan) check is must-fix when the finding is a real secret; if it is a clear false positive, put that under note with file/line — do not silently ignore a red check.
6. Split MVP from later work. A gap the acceptance criteria require is must-fix. A real gap the ticket does not require, including future reuse or a wider cleanup, is a potential follow-up. v1 that ships without a console UI AWS has for that service is a potential follow-up: `Debt: <service> console (from #<n>)`, unless an open issue already covers it. Web UI / console changes that skipped Open Design (`designing` status, mocks in `design/stackwrangler-console/` using `design/stackwrangler/` theme / web-clone) are must-fix. Enabled no-op / toast-only buttons or links are must-fix — unwired must be disabled with title="To implement" (Debt if v1); never-ship must be omitted.
7. For each potential follow-up, search first: `gh issue list --search "<keywords>" --state all --limit 20`, plus comments on issue #<n>. If an issue already covers it, cite that number and do not propose a new task. If none does, give a one-line title and why it is outside this ticket's MVP.

Return only:
- AC: one line per criterion, with met / missed / unclear
- must-fix: file:line and what is wrong. Or "none"
- potential-follow-up: title, why it is outside MVP, existing issue or "none". Or "none"
- note: optional

Do not edit files, push, or merge.
```
