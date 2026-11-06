# Recon summary — AWS S3 console dark (#304)

## Mode
Ref-based visual clone. Live Playwright recon **failed** (no Chrome / Chromium in runtime).

## Evidence
- `refs/aws-s3-console-dark-2026.png` (JFIF) — directory buckets + global chrome
- `refs/aws-s3-sidebar-nav.png` (PNG) — full S3 nav tree
- `refs/aws-s3-objects-tab.png` (JFIF) — objects table + tab strip
- `RECON/cloudscape-dark-tokens.json` — `@cloudscape-design/design-tokens@3.0.116` dark values

## Bound system (one sentence)
Cloudscape visual-refresh dark neutrals (`#161d26` surfaces, `#42b4ff` links, `#c6c6cd` body) plus AWS orange `#ec7211` for primary Create/Upload as seen in the refs.
