# Product version plan

**Persona:** a normal IT / CRM hosting company — multi-tenant or single-tenant CRM, B2B SFTP, APIs, workers, Postgres/MySQL, Redis, object storage, email, containers behind ALB/NLB, secrets, IAM, observability, IaC. Not every AWS SKU.

**Bar (vision):** data plane + authz for included services; console create/detail for shipped surfaces; stubs only where honestly labelled.

**Axes:** milestone = **pillar** (category); **label** = product cut. Current cut: [CURRENT_RELEASE](CURRENT_RELEASE).

**Priority order:** public basic release → core-stack bugs → security/authz (false confidence) → core debt/docs. Everything else = backlog with **no** version label.

---

## Pillars

Milestones are categories, not versions. Prefer these names (no `v1 —` prefix on new milestones):

| Pillar | Owns |
|--------|------|
| **Platform** | Public OSS, install, docs-site, console chrome, architecture map, release engineering |
| **Identity & authz** | IAM/STS, KMS, Secrets, Cognito, condition keys, resource policies, Simulate* |
| **Compute** | Lambda, ECS, EC2, ECR, ASG |
| **Object storage** | S3 |
| **Data stores** | DynamoDB, RDS/Aurora, cache, files |
| **Messaging** | SQS, SNS, EventBridge, Step Functions, Kinesis |
| **API Gateway** | HTTP + REST |
| **Networking** | VPC, ELB, WAF, DNS, CDN, ACM-on-listeners |
| **IaC** | CloudFormation, CDK, SAM, Terraform, Serverless samples |
| **Observability** | Logs, Metrics, Alarms, X-Ray stubs |
| **Data movement** | Transfer, Backup, DMS |
| **Org path** | Multi-service learning/staging path + dev-mode persistence |
| **Account & FinOps** | Orgs, Budgets, RAM, mirror tooling |
| **Enterprise networking** | TGW, VPN, Network Firewall / FMS |
| **Delivery tools** | CodePipeline, CodeBuild, CodeDeploy |
| **Stubs / out-of-footprint** | AI/ML, niche IaC, analytics lakes — almost never labelled |

Assign by *where the behaviour lives*. Platform only for install/docs/chrome/release engineering.

---

## Scoring

Project #8 fields **Impact** and **Effort** (numbers 1–5). Set with `./bin/issue-score.sh`.

### Impact

| Score | Meaning |
|-------|---------|
| **5** | False confidence / prod-break risk: local allows what AWS denies, or omits a check so a design that “works locally” fails or is insecure in prod |
| **4** | Core-path wrongness or hard block for public install/docs |
| **3** | Real gap on core stack with workaround; or important docs/debt for a shipped surface |
| **2** | Polish / secondary console depth / non-critical core debt |
| **1** | Niche, out-of-footprint, or speculative (`idea`) |

### Effort

| Score | Meaning |
|-------|---------|
| **1** | ≤ ~half day, small AC, localized |
| **2** | ~1 day, one service |
| **3** | 2–3 days or cross-cutting but clear |
| **4** | Multi-day / multi-service |
| **5** | Epic / unknown / needs design spike |

`priority_key = Impact * 10 - Effort` — sort key only.

---

## Core stack

README rows already Working/Partial for the hosting path: S3, IAM/STS, Lambda, ECS/EC2, ECR, APIGW, SQS/SNS/EB/SFN/Kinesis, RDS/DynamoDB, KMS/Secrets, CW Logs, VPC/ELB/SG (as shipped), CFN/CDK/SAM/TF.

New catalogue services stay **unlabelled** until a cut is deliberately opened for them.

---

## Cuts

### v0.0.1 — Baseline (historical)

First tagged account. Leftovers finish or roll forward unlabelled / into a matching later cut.

### v0.0.2 — Public *(shipped 2026-11-07)*

Install path, docs-site minimum, public hygiene. Gate: `public-ready` or blocks first public OSS cut.

### v0.0.3 — Trust *(shipped 2026-11-08)*

Core-stack bugs + security/authz that create false confidence. Gate: Impact ≥ 4 (Impact 5 always). 

### v0.0.4 — Accuracy *(active)*

Core Debt/docs/smoke-matrix/console depth on already-shipped services. Gate: Impact ≥ 3.

### v0.1.0 — Org path

Transfer→…→RDS learning/staging path honest end-to-end; path-critical only.

### Unlabelled backlog

Catalogue width (ElastiCache, Cognito, SES, Code*, FinOps, TGW, AI stubs, niche IaC, …). Milestone only. Do not pre-label `v0.1.1` / `v0.1.2` / `v1.0.0`.

### Later declaration (when opened)

`v1.0.0` remains a **declaration** cut (hosting-company ready), opened deliberately — not a parking label.

---

## In / out of long-term hosting footprint

**In-scope domains** (eventual Working/Partial): Network, Compute, Data, Integration, API, Security, Ops, Identity/account, Delivery, Enterprise attach (honest stubs OK), Product UX.

**Out of footprint (Stubs pillar, no release label):** AI/ML, IoT, media, WorkSpaces/AppStream, Lightsail, Amplify, MWAA, exotic DBs, Athena/Glue/Lake Formation, QuickSight/EMR, Classic ELB, Global Accelerator, VPC Lattice, EKS (revisit post-v1), Batch/Beanstalk/App Runner dataplanes, MSK/MQ unless forced.

---

## Board views

| View | Filter | Sort |
|------|--------|------|
| **v0.0.2** | `label:v0.0.2` | Impact ↓, Effort ↑ |
| **v0.0.3** | `label:v0.0.3` | Impact ↓, Effort ↑ |
| **v0.0.4** | `label:v0.0.4` | Impact ↓, Effort ↑ |
| **v0.1.0** | `label:v0.1.0` | Impact ↓, Effort ↑ |
| **High Impact** | Impact ≥ 4 (or `label:high-focus` until scored) | Impact ↓, Effort ↑ |
| **Unscored** | Impact empty | Updated ↓ |
| **No version** | open + no `v0.*` / `v1.*` release label | Impact ↓ |
| **Default** | full board | Status |

Hide premature views (`v0.1.1`, `v0.1.2`, `v1.0.0`, junk tabs) until those cuts reopen. Create the label + view together when opening a cut.

---

## How to use

1. Filter the board by cut view or `label:v0.0.2` (etc.).
2. New work: pillar + scores; version label only if theme + Impact gate match.
3. Debt: absorb small gaps in-parent; else evaluate-and-place (no auto `CURRENT_RELEASE`).
