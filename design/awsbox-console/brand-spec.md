# Brand spec — awsbox grey rose

Source: `design/awsbox/DESIGN.md` + `design/awsbox/tokens.css`. Dense dark operations console; same skeleton as AWS Console, different skin.

## System (one sentence)

Neutral charcoal chrome with a single grey-rose accent for filled actions, mark, active nav, and focus — never AWS orange, sky-blue links, or blue-charcoal.

## Tokens (OKLch + hex anchors)

```css
:root {
  --bg: oklch(0.205 0 0);           /* #141414 page */
  --surface: oklch(0.268 0 0);      /* #242424 panel */
  --fg: oklch(0.935 0 0);           /* #ECECEC */
  --muted: oklch(0.642 0 0);        /* #8D8D8D quiet */
  --border: oklch(0.348 0 0);       /* #3A3A3A */
  --accent: oklch(0.688 0.048 350); /* #B48AA0 grey rose */
}
```

Chrome surfaces (not in the six, still binding): `--chrome: #1C1C1C`, `--raised: #2E2E2E`, `--selected: #2A2428`, `--body: #C4C4C4`, `--link: #E6D0DA`, `--on-accent: #1A1A1A`.

## Type

- Display/UI: `"Source Sans 3", "Segoe UI", sans-serif`
- Mono (ARN / ids): `"Source Code Pro", ui-monospace, monospace`
- No Ember, no AWS icon font

## Posture rules

1. One filled accent button per toolbar; rose never tints chrome backgrounds.
2. Links and current nav use link rose (`#E6D0DA`), not sky blue.
3. Active nav: 3px accent bar + selected wash; inactive = body copy.
4. Dense console spacing: 32px controls, 40px rows, 2px/4px radii — not marketing cards.
5. Mark is an 18px rounded square with accent stroke and a vertical slot — no smile/arrow.
