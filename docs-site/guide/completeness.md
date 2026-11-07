# Completeness / status

Honest depth vs the [Vision](./vision) bar (data plane + authz, not catalogue theatre). For *why* this bar exists, see [Why](./why). How the pieces assemble: [Architecture](./architecture). Awkward topology / settings: [Fidelity](./fidelity). Source of truth for row-level notes: [README status matrix](https://github.com/kgz/stackwrangler/blob/main/README.md). Stubs stay stubs.

## Vision progress

Weighted across **64** README-matrix areas (Working ≈ 1.0 → Backlog = 0). Recompute when the matrix moves — do not invent a prettier number.

<div class="sw-progress" aria-label="Vision depth summary">
  <div class="sw-progress__headline">
    <span class="sw-progress__pct">46%</span>
    <span class="sw-progress__label">weighted vision depth · 64 areas</span>
  </div>
  <div class="sw-progress__track" role="img" aria-label="Catalogue mix: 14 working-ish, 30 partial, 7 stub, 13 backlog">
    <span class="sw-progress__seg sw-progress__seg--working"></span>
    <span class="sw-progress__seg sw-progress__seg--partial"></span>
    <span class="sw-progress__seg sw-progress__seg--stub"></span>
    <span class="sw-progress__seg sw-progress__seg--backlog"></span>
  </div>
  <ul class="sw-progress__legend">
    <li><span class="sw-progress__dot sw-progress__dot--working"></span>Working-ish · 14</li>
    <li><span class="sw-progress__dot sw-progress__dot--partial"></span>Partial / CLI · 30</li>
    <li><span class="sw-progress__dot sw-progress__dot--stub"></span>Stub / chrome · 7</li>
    <li><span class="sw-progress__dot sw-progress__dot--backlog"></span>Backlog · 13</li>
  </ul>
  <div class="sw-progress__meters">
    <div class="sw-progress__meter">
      <span>Catalogue</span>
      <div class="sw-progress__meter-bar"><div class="sw-progress__meter-fill" style="width:46%"></div></div>
      <strong>46%</strong>
    </div>
    <div class="sw-progress__meter">
      <span>Org-path hops</span>
      <div class="sw-progress__meter-bar"><div class="sw-progress__meter-fill" style="width:52%"></div></div>
      <strong>52%</strong>
    </div>
  </div>
</div>

Org-path (Transfer → Lambda → S3 → ECS → RDS + VPC) is ahead of the full catalogue because those hops partly exist — the single end-to-end smoke is still backlog.

## Legend

| Tag | Meaning |
|-----|---------|
| **Working** | Data plane + CLI smoke + console (or CLI-first with smoke) for the happy path |
| **Partial** | Works with known gaps (dual backends, bridge, limited authz, thin console) |
| **Control plane** | `create-*` / `describe-*` OK; little/no real traffic |
| **Sidecar** | Real bytes via a stackwrangler container, not native service listen |
| **Backlog** | Ticketed or named, not started |
| **Console chrome** | Nav / empty page only |

## Currently implemented

What you can actually exercise after `./bin/stackwrangler up` (happy path). Caveats stay in Gaps.

### Platform

| Area | Depth |
|------|--------|
| `./bin/stackwrangler up` + profile `local` | **Working** |
| Console shell (grey rose) | **Working** |
| Console labels (`STACKWRANGLER_LABELS`) | **Working** |
| Custom resource IDs + account in ARNs | **Working** |
| IAM enforcement on LocalEmu | **Partial** (on — deepen continuously) |

### Storage, compute, data plane

| Area | Depth |
|------|--------|
| S3 general purpose (SeaweedFS UI + LocalEmu for IaC/events) | **Working** UI · **Partial** dual-brain |
| Lambda (Docker invoke, console Create/detail) | **Working** |
| DynamoDB / SQS / SNS / EventBridge / Step Functions / Kinesis | **Working** (CLI smokes; SFN thin list [#175](https://github.com/kgz/awsl/issues/175); create/detail [#533](https://github.com/kgz/awsl/issues/533); others often console Debt) |
| CloudWatch Logs (basic) | **Working** |
| Transfer Family (native SFTP → S3) | **Partial** · **Sidecar** |
| EC2 / ECS / ECR | **Partial** · ECR registry **sidecar** |
| RDS Postgres / MySQL (Docker DB) | **Partial** · **Sidecar** |
| VPC / SG / ELBv2 / Route 53 (public + private) | **Partial** with smokes |
| WAFv2 (API GW associate; not real edge WAF) | **Partial** thin |
| API Gateway HTTP + REST | **Partial** |
| KMS / Secrets Manager / ACM | **Partial** · Secrets thin list [#176](https://github.com/kgz/awsl/issues/176); store/detail [#535](https://github.com/kgz/awsl/issues/535) |
| Multi-account + OIDC assume | **CLI + smoke** |

### IaC against the same account

| Tool | Depth |
|------|--------|
| Terraform (S3+Lambda + S3 backend/lock) | **Working** |
| CDK / SAM samples | **Working** |
| CloudFormation | **Partial** · StackSets/nested chrome [#95](https://github.com/kgz/awsl/issues/95) |
| Serverless Framework v3 | **Partial** |
| CodeDeploy (ECS blue/green + Lambda canary control plane) | **CLI + smoke** |

### Hosting footprint

Three honesty bands (same colours as the progress bar). Solid links = same-process path; dashed = **sidecar** (SeaweedFS, registry, SFTP, Postgres/MySQL).

<ClientOnly>
  <G6Diagram name="hosting-footprint" />
</ClientOnly>

## Gaps & TODO

Open work that blocks calling the vision “done”. Prefer Debt tickets over silent Partial forever.

### Product blockers (high)

| Gap | Why it matters | Track |
|-----|----------------|--------|
| Dual S3 (SeaweedFS `:8333` vs LocalEmu `:4566`) | Easy to point CLI/console/Lambda at different brains | [Concepts](./concepts) · unify later |
| Org-path **one E2E smoke** (Transfer → Lambda → S3 → ECS → RDS) | Vision demo path still not one script | [#90](https://github.com/kgz/stackwrangler/issues/90) / [#91](https://github.com/kgz/stackwrangler/issues/91) |
| IAM / workload-role **depth** | Authz must match AWS beyond the S3 deny lab | [#144](https://github.com/kgz/stackwrangler/issues/144) · resource-policy smokes exist |
| Transfer console / LOGICAL / IdP / AS2 | SFTP bytes Partial; console & fidelity incomplete | [#321](https://github.com/kgz/stackwrangler/issues/321) · [#322](https://github.com/kgz/stackwrangler/issues/322) · [#314](https://github.com/kgz/stackwrangler/issues/314) |
| ECS awsvpc / bridge / NLB fidelity | Org networking surprises | [#268](https://github.com/kgz/stackwrangler/issues/268) · [#247](https://github.com/kgz/stackwrangler/issues/247) · [#203](https://github.com/kgz/stackwrangler/issues/203) |
| RDS Aurora failover | Instance Create (Postgres/MySQL) wired; Aurora console create out of scope — CLI smoke + failover | [#225](https://github.com/kgz/stackwrangler/issues/225) |
| Console depth on Partial services | List-only or disabled Create → Debt | gap-check before `done` |

### Control plane / chrome (not “shipped”)

- Batch / Elastic Beanstalk / App Runner — **Control plane** stubs
- S3 specialty buckets / Access Points / Lens — **Console chrome**
- Metrics / Alarms / SSM / CloudTrail / Orgs — often **read-empty** for scanners

### Backlog (named, not started or thin)

- EKS · ElastiCache · EFS / FSx / EBS
- CloudFront · TGW / VPN / PrivateLink / Lattice
- Cognito · IAM Identity Center · SES / MSK / AppSync
- X-Ray / deeper observability
- Pulumi / Ansible examples · CodePipeline / CodeBuild / CodeArtifact
- Architecture map console canvas — [#389](https://github.com/kgz/stackwrangler/issues/389) (experimental; not on `main` yet)

### How we keep this honest

If a merge leaves a bridge, disabled console action, or happy-only smoke, file a **Debt:** ticket before calling the parent done ([docs/gap-check.md](https://github.com/kgz/stackwrangler/blob/main/docs/gap-check.md)).

## Version cuts

Product cuts (`v0.0.2`, `v0.0.3`, …) live in [`docs/version-plan.md`](https://github.com/kgz/stackwrangler/blob/main/docs/version-plan.md). Shipped cut notes: [Changelog](/guide/changelog). Catalogue milestones are orthogonal to depth: **execution order follows data-plane value**, not milestone number.
