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
5. Review the diff for bugs, missing tests, security, quality, duplicate code, and reuse. Security issues, bugs, and a missing test for behaviour this ticket adds are must-fix. Copying or reimplementing a helper that already exists in the repo is must-fix. A rename, format nit, or speculative "might reuse later" is not must-fix.
6. Split MVP from later work. A gap the acceptance criteria require is must-fix. A real gap the ticket does not require, including future reuse or a wider cleanup, is a potential follow-up.
7. For each potential follow-up, search first: `gh issue list --search "<keywords>" --state all --limit 20`, plus comments on issue #<n>. If an issue already covers it, cite that number and do not propose a new task. If none does, give a one-line title and why it is outside this ticket's MVP.

Return only:
- AC: one line per criterion, with met / missed / unclear
- must-fix: file:line and what is wrong. Or "none"
- potential-follow-up: title, why it is outside MVP, existing issue or "none". Or "none"
- note: optional

Do not edit files, push, or merge.
```
