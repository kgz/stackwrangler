---
name: docs-catalog
description: >-
  Ship or backlog public docs: interactions catalog pages, docs-site shots,
  Doc: tickets. Use when documenting edges, promo/README copy, gap-check Doc:
  rows, Agent cursor-batch-docs, or screenshot capture via docs-capture.
---

# Docs catalog

Prefer **docs in the parent PR**. File `Doc: … (from #<n>)` only when blocked.

Read [docs/docs-catalog.md](../../../docs/docs-catalog.md) for ticket shape, page template, and capture commands.

## When

- User asks for docs / promo / screenshots / interactions catalog
- Gap-check public docs / screenshot / interaction edge is NO
- Project Agent is `cursor-batch-docs`

## Do

1. Add or update `docs-site/guide/interactions/<slug>.md` and a row on `index.md`.
2. Status must be one of: `shipped` | `partial` | `gap` | `not-valid`. Link Debt/issues for gaps.
3. Prove-it section: real `./bin/…-smoke.sh` from smoke-matrix / test-paths. No unsmoked claims.
4. UI change → `./bin/docs-capture.sh` (console up on `:3000`). Register shots in `docs/console-shots.md`.
5. Wire VitePress nav only if adding a new top-level section (seed already lists Interactions).
6. After the PR exists (or after a docs push to an open PR), post a **separate** PR comment — not folded into the PR body or the implement/review notes. Use the template below.

## PR comment (required)

One dedicated comment on the PR (`gh pr comment`), titled exactly `## Docs`. Do not merge this into Summary / Test plan / Worker / Review comments.

```markdown
## Docs

### Areas added / updated
- `docs-site/guide/interactions/<slug>.md` — <one-line what changed>
- `docs-site/guide/interactions/index.md` — row for <edge>
- `docs/console-shots.md` / `docs/assets/console/<shot>.png` — <if any>
- README / other — <if any>

### Follow-up tickets
- #N — Doc: … (from #<parent>) — <why blocked>
- none
```

List every docs-site / README / capture path you touched. If you filed no `Doc:` tickets, write `none` under Follow-up tickets (do not omit the section).

## Voice

- Short sentences. Name commands and ports.
- **Linux-first host voice.** Assume a Linux host (native or any Linux). Do not lead with WSL / Docker Desktop WSL as the default (bad: `WSL: ports bind to 127.0.0.1…`). Ports/`127.0.0.1`/Docker guidance speaks to Linux first; Windows-via-WSL is a secondary note only when the technical detail is still true (e.g. `/etc/wsl.conf`). See #491.
- No hype, no “delve” / “robust end-to-end solution”, no AI watermarks.
- Mark **gap** and **not-valid** in plain words.

## Blocked

Open a backlog ticket and stop:

```text
Title: Doc: <short gap> (from #<parent>)
```

Label `$(cat docs/CURRENT_RELEASE)`, tracker row, link from catalog index. Do not invent screenshots. Never use `design/**/refs/` AWS recon PNGs as product shots.

## Out of scope

Debt/Open Design flows (unchanged). Pages deploy (#425). Flipping the repo public (#435).
