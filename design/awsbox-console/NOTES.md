# awsbox-console · clone notes

## Brand
- Spec: `design/awsbox/DESIGN.md` + `tokens.css` → project `brand-spec.md`
- Paint: grey rose `#B48AA0` Create / mark / focus; links `#E6D0DA`; page `#141414`; chrome `#1C1C1C`
- Forbidden: AWS orange, sky-blue links, blue-charcoal chrome, Amazon smile, Ember, earlier teal/green

## Dead controls

Rule: not wired yet → keep visible, `disabled` + `aria-disabled="true"` + `title="To implement"`. Never ship → omit. Selection-only gates → `title="Select a row"`. No toast-only / enabled no-ops. Palette unchanged (grey rose).

### Disabled (`title="To implement"`)
- All primary **Create** buttons; Refresh; table settings; Import; object Download / Open / Delete / Copy URI·URL; bucket detail tabs beyond Objects
- Shared chrome: CloudShell, notifications prefs, Help Info/Support, Settings, account menu links + multi-session / switch role / sign out, copy account ID, search settings, services rail Favorites / All apps / All services, service-category buttons, page-info
- Favorites / Recently visited tiles for non-S3 services (shipped under #319)

### Disabled (`title="Select a row"`)
- List toolbars: Copy ARN, Empty, Delete when selection-gated

### Omitted (never ship in this mock set)
- Red “insufficient permissions” / Access denied banners (refs show them; mocks use empty/no-data instead)
- Marketplace **see all** / **View product**
- Account menu **Agent Toolkit for AWS**

### Wired (kept enabled)
- Real `href` navigation (GP ↔ Directory tabs, S3 nav, favorites S3, search hits, docs Learn more)
- Storage Lens **View dashboard** on GP side widget → `storage-lens.html`
- Region switcher (updates label)
- Working global search; Services menu open/close
- Bucket-objects **Actions ▾** opens menu (menu items disabled)

Regenerator: `node scripts/generate-screens.mjs` (S3 only).

## Issue #304 — S3 missing UI

### Mode
- Visual console clone for S3 chrome + missing nav screens
- Designs only — HTML under `screens/`; React `console/` untouched
- Empty panels (table / vector / access points / FSx / grants / Storage Lens / Batch): heading + disabled Refresh + disabled Create + empty copy, **no table** (matches local-stack stubs)

### Shared chrome check
| Check | Result |
|---|---|
| Topnav mark `awsbox` | Pass |
| Create rose `#B48AA0` | Pass — `--awsbox-accent` |
| Links `#E6D0DA` | Pass |
| Page / chrome `#141414` / `#1C1C1C` | Pass |
| Services menu / search / region / account | Pass (menus open; unwired items disabled) |
| Favorites service icons | Pass (S3 linked; others disabled until #319) |

### Deliverables
| File | Covers |
|---|---|
| Shared `assets/console.js` + CSS | Services, search, CloudShell/notify/help/settings, account, region, favorites icons, page info |
| `directory-buckets.html` | Tabs + All AWS Regions badge, latency copy, Copy ARN/Empty/Delete/Import, find, pager, columns |
| `general-purpose-buckets.html` | Copy ARN + Import, pager, Directory tab link, side widgets |
| `bucket-objects.html` | Permissions/Metrics/Management/Access Points tabs, Copy URL, Actions, Learn more, pager |
| `file-systems.html` / `iam-access-analyzer.html` / `account-organization-settings.html` / `marketplace-for-s3.html` | Nav placeholders |
| Empty panels listed above | Heading + Refresh + Create + no table |

### Refs
- `refs/aws-s3-*.png`, `refs/aws-console-*.png` — dark console captures
- Permission-error banners omitted on purpose

### Gaps
1. Empty-panel screens intentionally simpler than full AWS table chrome (ticket acceptance).
2. Non-S3 service screens live under #319 — not claimed here.
3. Create / many Actions disabled with `title="To implement"`.

## Run

```bash
node scripts/generate-screens.mjs
```

Open `index.html` in Open Design preview or a static file server from this directory.

## License / trademark
AWS name, logo, and console UI are Amazon trademarks. Local design reference only — do not publish as an AWS product.
