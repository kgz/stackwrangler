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

## Voice

- Short sentences. Name commands and ports.
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
