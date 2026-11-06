# stackwrangler-console · clone notes

## Brand
- Spec: `design/stackwrangler/DESIGN.md` + `tokens.css` → project `brand-spec.md`
- Paint: grey rose `#B48AA0` Create / mark / focus; links `#E6D0DA`; page `#141414`; chrome `#1C1C1C`
- Forbidden: AWS orange, sky-blue links, blue-charcoal chrome, Amazon smile, Ember, earlier teal/green

## Dead controls

Rule: not wired yet → keep visible, `disabled` + `aria-disabled="true"` + `title="To implement"`. Never ship → omit. Selection-only gates → `title="Select a row"`. No toast-only / enabled no-ops. Palette unchanged (grey rose).

### Disabled (`title="To implement"`)
- All primary **Create** buttons; Refresh; table settings; Import; object Download / Open / Delete / Copy URI·URL; bucket detail tabs beyond Objects
- Shared chrome: CloudShell, notifications prefs, Help Info/Support, Settings, account menu links + multi-session / switch role / sign out, copy account ID, search settings, services rail Favorites / All apps / All services, service-category buttons, page-info

### Disabled (`title="Select a row"`)
- List toolbars: Copy ARN, Empty, Delete when selection-gated

### Omitted (never ship in this mock set)
- Red “insufficient permissions” / Access denied banners (refs show them; mocks use empty/no-data instead)
- Marketplace **see all** / **View product**
- Account menu **Agent Toolkit for AWS**

### Wired (kept enabled)
- Real `href` navigation (GP ↔ Directory tabs, S3 nav, favorites EC2/ECS/IAM/Lambda/S3, search hits, docs Learn more)
- Storage Lens **View dashboard** on GP side widget → `storage-lens.html`
- Region switcher (updates label)
- Working global search; Services menu open/close
- Bucket-objects **Actions ▾** opens menu (menu items disabled)

Regenerator: `node scripts/generate-screens.mjs` (S3) · `node scripts/generate-service-screens.mjs` (#319).

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
| Favorites service icons | Pass (EC2 / ECS / IAM / Lambda / S3 linked — #319) |

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
2. Non-S3 service screens: see Issue #319 below.
3. Create / many Actions disabled with `title="To implement"`.

## Issue #319 — built services (non-S3)

### Mode
- Grey-rose dark console mocks for shipped awsbox services (not S3 — that stays #304)
- Layout mirrors AWS console list/detail chrome via shared `assets/` + generator
- Designs only — React `console/` untouched

### Deliverables
| File | Covers |
|---|---|
| Shared chrome updates | Favorites + Services “Recently visited” + search index for IAM/Lambda/Logs/APIGW/CFN/Transfer/RDS/ECS/EC2 |
| `iam-users.html` (+ `-empty`) | Users list / empty panel |
| `lambda-functions.html` (+ `-empty`) | Functions list / empty |
| `logs-log-groups.html` (+ `-empty`) | Log groups list / empty |
| `apigateway-http-apis.html` (+ `-empty`) | HTTP APIs tab / empty |
| `cloudformation-stacks.html` + `cloudformation-stack-detail.html` | Stacks list + detail tabs (info/events/resources/outputs/parameters/template) |
| `transfer-servers.html` + `transfer-server-detail.html` | Servers list + users + data plane |
| `rds-databases.html` + `rds-instance-detail.html` | Databases list + connectivity/config |
| `ecs-clusters.html` + `ecs-cluster-detail.html` | Clusters list + services/tasks |
| `ec2-instances.html` | Instances list |
| `ec2-vpcs.html` + `ec2-vpc-detail.html` | VPCs list + detail tabs (details/CIDRs/subnets/tags) |
| `ec2-load-balancers.html` | Load balancers list |

### Gaps
1. Create / Actions / Refresh disabled with `title="To implement"` (design-only).
2. React follow-ups: #347 (S3), #349 (services), full Create/detail #350+.

## Issue #176 — Secrets Manager list

### Mode
- Web-clone of the AWS Secrets Manager **Secrets** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources touched
- Structure follows existing thin lists (`iam-users.html` / `sfn-state-machines.html`): h1 + description + card toolbar + find/pager + table
## Issue #178 — Kinesis Data streams list

### Mode
- Web-clone of the AWS Kinesis **Data streams** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kms-keys.html` / `secrets-list.html` / `sfn-state-machines.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `secrets-list.html` | Name / Description / Last retrieved / Created on · 3 rows (`app/oauth/client`, `rds!db-master`, `transfer/tenant/creds`) |
| `secrets-list-empty.html` | Empty twin · Refresh + Store a new secret + empty panel |

### Dead controls (`title="To implement"`)
- Store a new secret, Delete, Rotate, Refresh, header filters, secret name links, table settings
- Working: find field filters rows through shared `data-find-table` wiring; pager and nav links unchanged
| `kinesis-streams.html` | Name / Status / Capacity mode / Monitoring / Created · 3 rows (`app-events`, `awsbox-kinesis-demo`, `orders-ingest`) |
| `kinesis-streams-empty.html` | Empty twin · Refresh + Create data stream + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create data stream, Refresh, table settings, column filters, stream name dead links
- `title="Select a row"`: Delete
- Working: find field (`data-find-table`), pager chrome, Services/search → `kinesis-streams.html`

## Run

```bash
node scripts/generate-screens.mjs          # S3 (#304)
node scripts/generate-service-screens.mjs  # built services (#319) + index
```

Open `index.html` in Open Design preview or a static file server from this directory.

## License / trademark
AWS name, logo, and console UI are Amazon trademarks. Local design reference only — do not publish as an AWS product.

## Issue #177 — KMS Customer managed keys list

### Mode
- Web-clone of the AWS KMS **Customer managed keys** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `secrets-list.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `kms-keys.html` | Alias / Key ID / Status / Key spec / Key usage / Creation date · 3 rows (`alias/app-data`, `alias/local-dev`, `alias/secrets-envelope`) |
| `kms-keys-empty.html` | Empty twin · Refresh + Create key + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create key, Refresh, table settings, column filters, alias dead links
- `title="Select a row"`: Delete, Schedule key deletion
- Working: find field (`data-find-table`), pager chrome, Services/search → `kms-keys.html`

## Issue #93 — CloudFormation Create stack wizard

### Mode
- Web-clone of AWS CFN **Create stack** (template ready → upload/paste → stack name) into grey-rose console chrome
- Designs under `screens/`; React wires CreateStack + describe poll in `console/`
- OD agent runs failed (daemon GLIBC/opencode EACCES during batch); mocks landed to match `lambda-create-function.html` + CFN list chrome

### Deliverables
| File | Covers |
|---|---|
| `cloudformation-create-stack.html` | Prerequisite choices · template source (upload / paste / S3 stub) · stack name · parameters empty · Create |
| `cloudformation-stacks.html` | Create stack ▾ → create wizard (enabled link) |

### Dead controls
- `title="To implement"`: Use a sample template, Create template in Designer, Amazon S3 URL
- Working: Template is ready, Upload file, Paste body, Stack name, Cancel → stacks list, Create stack → detail mock

