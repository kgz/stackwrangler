# Docs catalog (interactions + Doc: follow-ups)

Prefer shipping docs in the **parent PR**. File a **Doc:** backlog ticket only when blocked (no seed/screenshot path, out of scope this ticket, needs a dedicated pass).

Coverage truth for smokes stays [smoke-matrix.md](smoke-matrix.md) / [test-paths.md](test-paths.md). The catalog is the **narrative** layer (what talks to what) so agents and humans can find honest shipped behaviour.

## Doc: ticket shape

```text
Title: Doc: <short gap> (from #<parent>)
Body: Why / Goal / Acceptance / Related #<parent>
  - pages to add/update (docs-site paths)
  - edges to document (interactions slug)
  - screenshots required (yes/no + names in docs/console-shots.md)
Milestone: same area as parent
Label: $(cat docs/CURRENT_RELEASE)
Board: backlog
Tracker: bin/board-tracker.tsv
Link from catalog index or parent PR
```

Batch Agent id: `cursor-batch-docs` (Project field, not a label).

## Interactions catalog

```text
docs-site/guide/interactions/
  index.md           # table + legend only
  <edge-slug>.md     # one edge per file
```

**Status values:** `shipped` | `partial` | `gap` | `not-valid`

| Status | Meaning |
|--------|---------|
| shipped | Happy path smoked; claims match behaviour |
| partial | Works with known gaps (link Debt/issues) |
| gap | Expected path not proven yet — do not market as ready |
| not-valid | We do **not** claim this path (wrong emulator story, etc.) |

### Per-edge page template

```markdown
# <Edge name>

<one line what it does>

**Status:** partial · Gaps: [#N](…)

## Sequence

1. …
2. …

## Prove it

\`\`\`bash
./smokes/<area>/<smoke>.sh
\`\`\`

## Console

![…](/assets/console/<shot>.png)   <!-- only if UI-relevant; from docs-capture -->
```

Voice: short sentences, real `./bin/…` commands, no hype. Mark **gap** / **not-valid** explicitly. Never use AWS recon PNGs from `design/**/refs/` as product shots.

## Screenshots

```bash
./bin/stackwrangler up
./bin/stackwrangler console   # :3000 healthy
./bin/docs-capture.sh         # Playwright → docs/assets/console/
```

Shot registry: [console-shots.md](console-shots.md). No seed for a shot → file **Doc:**; do not invent images.

Skill: `.cursor/skills/docs-catalog/SKILL.md`.

## Diagrams (AntV G6)

Product topology / “server” diagrams use **G6**, not Mermaid:

- Component: `docs-site/.vitepress/theme/components/G6Diagram.vue`
- Registry: `docs-site/.vitepress/theme/diagrams/` — add a `*.ts` module, export from `index.ts`
- In markdown: `<ClientOnly><G6Diagram name="hosting-footprint" /></ClientOnly>`

Sequence one-liners on interaction pages may still use Mermaid until moved.
