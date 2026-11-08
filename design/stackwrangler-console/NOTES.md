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
| `ecs-create-cluster.html` + `ecs-task-detail.html` | Create cluster + task depth (#146) |
| `ec2-instances.html` + `ec2-instance-detail.html` | Instances list + detail (#146) |
| `ec2-vpcs.html` + `ec2-vpc-detail.html` | VPCs list + detail tabs (details/CIDRs/subnets/tags) |
| `ec2-load-balancers.html` | Load balancers list |

### Gaps
1. Create / Actions / Refresh disabled with `title="To implement"` (design-only).
2. React follow-ups: #347 (S3), #349 (services), full Create/detail #350+.

## Issue #174 — DynamoDB Tables list

### Mode
- Web-clone of the AWS DynamoDB **Tables** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kinesis-streams.html` / `kms-keys.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `dynamodb-tables.html` | Name / Status / Partition key / Sort key / Indexes / Capacity mode · 3 rows (`orders`, `awsbox-ddb-demo`, `sessions`) |
| `dynamodb-tables-empty.html` | Empty twin · Refresh + Create table + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create table, Refresh, table settings, column filters, table name dead links
- `title="Select a row"`: Delete
- Working: find field (`data-find-table`), pager chrome, Services/search/favorites → `dynamodb-tables.html`

## Issue #176 — Secrets Manager list

### Mode
- Web-clone of the AWS Secrets Manager **Secrets** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources touched
- Structure follows existing thin lists (`iam-users.html` / `sfn-state-machines.html`): h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `secrets-list.html` | Name / Description / Last retrieved / Created on · 3 rows (`app/oauth/client`, `rds!db-master`, `transfer/tenant/creds`) |
| `secrets-list-empty.html` | Empty twin · Refresh + Store a new secret + empty panel |

### Dead controls (`title="To implement"`)
- Store a new secret, Delete, Rotate, Refresh, header filters, secret name links, table settings
- Working: find field filters rows through shared `data-find-table` wiring; pager and nav links unchanged

## Issue #178 — Kinesis Data streams list

### Mode
- Web-clone of the AWS Kinesis **Data streams** list into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kms-keys.html` / `secrets-list.html` / `sfn-state-machines.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `kinesis-streams.html` | Name / Status / Capacity mode / Monitoring / Created · 3 rows (`app-events`, `awsbox-kinesis-demo`, `orders-ingest`) |
| `kinesis-streams-empty.html` | Empty twin · Refresh + Create data stream + empty panel · link to sample rows |

### Dead controls (post-#539)
- `title="To implement"`: Refresh, table settings, column filters
- `title="Select a row"`: Delete (static mock; React wires confirm)
- Working: Create → `kinesis-create-data-stream.html`; Name → `kinesis-stream-detail.html`; find field; pager; nav

## Issue #539 — Kinesis create + detail (from #178)

### Mode
- Extend #178 list mocks with Create + stream detail (grey-rose chrome)
- `./bin/od-design-run.sh --issue 539` failed (daemon HTTP 404 on conversation messages; agents: opencode only). Hand mocks match `sfn-create-state-machine.html` / `sfn-state-machine-detail.html`
- LocalEmu-shaped provisioned / on-demand sample — no real AWS writes

### Deliverables
| File | Covers |
|---|---|
| `kinesis-create-data-stream.html` | Name · Provisioned (shard count) / On-demand · retention/encryption/tags stubs |
| `kinesis-stream-detail.html` | Details / Shards tabs · Delete + Put records stubs |
| `kinesis-streams.html` (+ empty) | Create → create screen; Name → detail |

### Dead controls (`title="To implement"`)
- Configure retention / encryption / tags, Put records, Delete (static detail), Refresh (static mock)
- Column filters on list remain stubbed

## Issue #615 — Kinesis put / retention / encryption / tags (from #539)

### Mode
- Hand-update #539 create + detail mocks (grey-rose); OD optional
- Wire React against LocalEmu PutRecord, retention increase/decrease, Start/StopStreamEncryption, Add/List/RemoveTags

### Deliverables
| File | Covers |
|---|---|
| `kinesis-create-data-stream.html` | Retention hours · encryption NONE/KMS · tags table |
| `kinesis-stream-detail.html` | Put records · Edit retention/encryption · Tags tab |

### Dead controls remaining
- List column filters (`FilterHeader`) stay `title="To implement"` (shared console stub; not LocalEmu APIs)

## Issue #167 — SQS Queues list

### Mode
- Web-clone of the AWS SQS **Queues** list into grey-rose console chrome
- Designs only for OD pass — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kinesis-streams.html` / `secrets-list.html` / `sns-topics.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `sqs-queues.html` | Name / Type / Created / Messages available / Messages in flight · 3 rows (`awsbox-sqs-demo`, `notifications.fifo`, `orders-ingress`) |
| `sqs-queues-empty.html` | Empty twin · Refresh + Create queue + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create queue, Refresh, table settings, column filters, queue name dead links
- `title="Select a row"`: Delete
- Working: find field (`data-find-table`), pager chrome, Services/search → `sqs-queues.html`

## Issue #189 — API Gateway REST APIs

### Mode
- Web-clone of AWS API Gateway **REST APIs** (v1) list + detail into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources touched
- Structure mirrors `apigateway-http-apis.html` for the list; detail uses Lambda-style tab panels

### Deliverables
| File | Covers |
|---|---|
| `apigateway-rest-apis.html` | HTTP\|REST tabs · Name / API ID / Description / Created / Protocol / Endpoint · 2 rows (`demo-rest`, `orders-api`) · name → detail |
| `apigateway-rest-apis-empty.html` | Empty twin · Refresh + Create + empty panel · link to sample rows |
| `apigateway-rest-api-detail.html` | Overview · Invoke URL · Resources/methods · Authorizers · Stages (`demo-rest`) |
| HTTP list screens | Matching REST tab links (populated ↔ empty twins) |
| Shared chrome | Sidebar REST APIs · search Feature `REST APIs` / `demo-rest` |

### Dead controls
- List: `title="To implement"` Refresh, Create, table settings, column filters; `title="Select a row"` Delete
- Detail: Refresh, Deploy API, Actions, Create resource/method/authorizer/stage
- Working: HTTP ↔ REST tabs; name cells → detail; detail tab panels; find field; Services/search → REST list

## Run

```bash
node scripts/generate-screens.mjs          # S3 (#304)
node scripts/generate-service-screens.mjs  # built services (#319) + index
```

Open `index.html` in Open Design preview or a static file server from this directory.

## License / trademark
AWS name, logo, and console UI are Amazon trademarks. Local design reference only — do not publish as an AWS product.

## Issue #172 — SNS Topics list

### Mode
- Web-clone of the AWS SNS **Topics** list into grey-rose console chrome
- Designs only for OD pass — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kinesis-streams.html` / `secrets-list.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `sns-topics.html` | Name / Type / ARN · 3 rows (`orders-events`, `awsbox-sns-demo.fifo`, `app-alerts`) |
| `sns-topics-empty.html` | Empty twin · Refresh + Create topic + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create topic, Refresh, table settings, column filters, topic name dead links
- `title="Select a row"`: Delete
- Working: find field (`data-find-table`), pager chrome, Services/search → `sns-topics.html`

## Issue #146 — ECS/EC2 console depth

### Mode
- Web-clone depth for ECS create/cluster/task and EC2 instance detail into grey-rose chrome
- LocalEmu-shaped sample rows; no real AWS resources / API writes in design
- Create cluster is a thin name form (capacity providers / EC2 infra stay stubbed)
- Task Logs: clear stub — CloudWatch stream not wired in LocalEmu console

### Deliverables
| File | Covers |
|---|---|
| `ecs-create-cluster.html` | Cluster name + Fargate selected; EC2 infra disabled |
| `ecs-cluster-detail.html` | Overview (+ pending/registered) · richer services/tasks · task link |
| `ecs-task-detail.html` | Config · containers table · Logs stub |
| `ec2-instance-detail.html` | Summary + networking (VPC/subnet/SG/IAM) |
| `ecs-clusters.html` / `ec2-instances.html` | Create Cluster → create page; instance ID → detail |

### Dead controls
- `title="To implement"`: Launch instance, EC2 infra radio, task Stop / View in CloudWatch Logs, cluster Actions, instance state/Actions
- Working links: Create Cluster, cluster/task/instance detail navigation

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

## Issue #145 — RDS Create database

### Mode
- Web-clone of AWS RDS **Create database** (Standard create) into grey-rose console chrome
- OD daemon runs failed here (`cursor-agent` GLIBC; `opencode` EACCES on `~/.config/opencode`); mock landed by hand against `lambda-create-function.html` + existing RDS list chrome
- LocalEmu-shaped subset only — no real AWS resources

### Deliverables
| File | Covers |
|---|---|
| `rds-create-database.html` | Standard create · Postgres/MySQL engines · settings/credentials · dead VPC/SG/Multi-AZ |
| `rds-databases.html` | Create database → enabled link to create screen |

### Dead controls (`title="To implement"`)
- Easy create, Aurora engine, VPC / subnet / SG / Multi-AZ selects
- Working in mock: engine toggle (Postgres/MySQL), Cancel, Create → detail sample

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

## Issue #94 — CloudFormation Update + change sets

### Mode
- Web-clone of AWS CFN **Update stack** / **Change sets** into grey-rose console chrome
- OD `./bin/od-design-run.sh --issue 94` started (project `stackwrangler-console-94`); container agents failed (cursor-agent GLIBC_2.36; opencode EACCES on `~/.config/opencode`). Mocks landed to match existing CFN screens + AWS tab layout.
- Designs under `screens/`; React follows in `console/`

### Deliverables
| File | Covers |
|---|---|
| `cloudformation-stack-detail.html` | Change sets tab + Update ▾ → update / create change set |
| `cloudformation-stacks.html` | Update ▾ menu links |
| `cloudformation-update-stack.html` | Template replace (paste / upload) |
| `cloudformation-create-change-set.html` | Name + description + template body |
| `cloudformation-change-set-detail.html` | Overview + changes table · Execute / Delete |
| `cloudformation-change-sets-empty.html` | Empty twin |

### Dead controls
- `title="To implement"`: Refresh, S3 template URL, Stack actions
- `title="Select a row"`: Execute / Delete on change-set list when none selected
- Working (mock hrefs): Update stack, Create change set, change set name → detail; Create stack ▾ → #93 wizard

## Issue #95 — StackSets + nested stacks chrome

### Mode
- Web-clone of AWS CloudFormation **StackSets** list + nested stack navigation into grey-rose console chrome
- Designs only for OD; React console wires ListStackSets (often empty) + ParentId/RootId / nested resource links
- Structure follows `kms-keys.html` / `cloudformation-stacks.html`

### Deliverables
| File | Covers |
|---|---|
| `cloudformation-stacksets.html` | Name / Description / Status / Permission model · 3 sample rows |
| `cloudformation-stacksets-empty.html` | Empty twin · honesty copy for LocalEmu ListStackSets |
| `cloudformation-stack-parent-detail.html` | Root stack · Resources `AWS::CloudFormation::Stack` links to nested |
| `cloudformation-stack-detail.html` | Nested child · Parent / Root overview links |

### Dead controls
- `title="To implement"`: Create StackSet, Refresh, table settings, StackSet name links
- `title="Select a row"`: Delete StackSet
- Working: find field, pager chrome, nav → StackSets, nested/parent hrefs between detail mocks

## Issue #173 — EventBridge rules + event buses lists

### Mode
- Web-clone of the AWS EventBridge **Rules** and **Event buses** lists into grey-rose console chrome
- Designs only — LocalEmu-shaped sample rows; no real AWS resources / API writes
- Structure follows `kinesis-streams.html` / `secrets-list.html`: h1 + description + card toolbar + find/pager + table

### Deliverables
| File | Covers |
|---|---|
| `eventbridge-rules.html` | Name / Status / Event bus / Type / Updated · 3 rows (`awsbox-events-demo`, `cleanup-schedule`, `orders-route`) |
| `eventbridge-rules-empty.html` | Empty twin · Refresh + Create rule + empty panel · link to sample rows |
| `eventbridge-buses.html` | Name / Type / Description · `default` + `app-domain` + `orders` |
| `eventbridge-buses-empty.html` | Empty twin · Refresh + Create event bus + empty panel · link to sample rows |

### Dead controls
- `title="To implement"`: Create rule / Create event bus, Refresh, table settings, column filters, name dead links
- `title="Select a row"`: Delete
- Working: find field (`data-find-table`), pager chrome, Services/search → `eventbridge-rules.html` / `eventbridge-buses.html`

## Issue #543 — REST create / deploy (hand mocks)

### Mode
- OD daemon reachable but agents failed (`cursor-agent` missing; `opencode` spawn ENOENT). Hand mocks landed instead of a successful `./bin/od-design-run.sh` web-clone.
- Screens: `apigateway-rest-api-create.html`, `apigateway-rest-api-deploy.html`; list/detail Create + Deploy API enabled and linked. Delete / Actions / Create resource|method|authorizer|stage stay `title="To implement"` in mocks (resource/method wired in React).

## Issue #616 — REST method integration picker (hand mocks)

### Mode
- OD daemon reachable; hand grey-rose mock (same path as #543) for Create method with integration type picker.
- Screen: `apigateway-rest-api-create-method.html`. Wired types: MOCK, Lambda `AWS_PROXY`, `HTTP_PROXY`. Disabled `title="To implement"`: AWS (non-proxy), HTTP (non-proxy), VPC link.
- Detail resources toolbar: Create method → `apigateway-rest-api-create-method.html`; Edit integration → `apigateway-rest-api-edit-integration.html` (selected `/hello` GET in mock).

