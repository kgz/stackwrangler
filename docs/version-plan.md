# Product version plan → v1.0

**Persona:** a normal IT / CRM hosting company at scale — multi-tenant or single-tenant CRM, B2B integrations (often SFTP), APIs, workers, Postgres/MySQL, Redis, object storage, email, containers behind ALB/NLB, secrets, IAM, observability, IaC. Not every AWS SKU.

**Bar (vision):** data plane + authz for included services; console create/detail for shipped surfaces; stubs only where honestly labelled.

**Axes:** milestone = catalogue area; **label** = product cut below. Current cut: [CURRENT_RELEASE](CURRENT_RELEASE).

Ticket numbers are the best-known open issues as of 2026-10-26; adjust when closing/splitting.

---

## In scope for v1.0 (hosting footprint)

| Domain | Include | Depth target |
|--------|---------|--------------|
| Network | VPC, SG, ALB/NLB, Route 53, ACM, WAF, PrivateLink, CloudFront (enough for static/app edge) | Data plane where we already smoke; WAF/CF deepen |
| Compute | EC2, ECS, Lambda, ECR, ASG (thin) | Working + authz |
| Data | S3, RDS/Aurora MySQL+Postgres, DynamoDB, ElastiCache Redis, EFS | Real containers / Redis sidecar where needed |
| Integration | SQS, SNS, EventBridge, Step Functions, Kinesis, Transfer Family, SES | Data plane + authz |
| API | API Gateway HTTP+REST | Working |
| Security | IAM/STS, KMS, Secrets, Cognito user pools | Authz first-class |
| Ops | CloudWatch Logs/Metrics/Alarms, SSM, CloudTrail, Backup | Usable for staging |
| Identity / account | Multi-account AssumeRole, Organizations (enough), Identity Center stub→usable | Learning + smoke |
| Delivery | CFN/CDK/SAM/Terraform/Serverless, CodePipeline+CodeBuild (or thin + GH Actions docs) | Deploy against `local` |
| Enterprise attach | Site-to-Site VPN + TGW **stubs with honest limits**, DMS for migrations | Control plane + documented gaps OK |
| Product UX | Console create/detail for shipped services; optional account map | v0.0.2 then deepen |

## Out of v1.0 (no release label — do not schedule)

AI/ML (Bedrock, SageMaker, Rekognition/Textract/…), IoT, MediaLive/Convert, WorkSpaces/AppStream, Lightsail, Amplify, MWAA, Pinpoint, exotic DBs (Redshift/Neptune/Timestream/DocumentDB/Keyspaces), Athena/Glue/Lake Formation, QuickSight/EMR/DataBrew, Classic ELB, Global Accelerator, VPC Lattice, Network Firewall (unless a later enterprise spike), EKS (ECS covers most hosting; revisit post-v1), Batch/Beanstalk/App Runner dataplanes, MSK/MQ (unless a customer path forces it).

---

## Cuts

### v0.0.1 — Baseline (historical)

First tagged account: S3, IAM/STS, Lambda, Logs, API GW, ECS/EC2, CFN/CDK/SAM/TF path, messaging (SQS/SNS/EB/SFN/Kinesis), KMS/Secrets, Transfer (sidecar), RDS, ELBv2/VPC/SG/R53-private, ECR, multi-account/OIDC, mirror synthetic, Prowler scoped.

Open leftovers still labelled `v0.0.1` finish into this cut or roll forward when `CURRENT_RELEASE` advances.

### v0.0.2 — Console UI + bugs *(active planning focus)*

**Theme:** create/detail/wizards for **already shipped** services; fix incorrect AWS behaviour.

| Include | Tickets (open) |
|---------|----------------|
| Console epic + CFN write chrome | #350, #93–95, #147, #251, #343 |
| Per-service console debt | #145–146, #167, #172–178, #189, #217, #241, #245, #310, #313, #321, #324, #333, #351–354 |
| Implement OD mocks (if still open) | #347, #349 |
| Bugs / authz / data-plane wrongness | #154, #181, #187, #190, #219, #236–237, #242–243, #247, #254, #282, #285, #306–307, #315, #328 |

Not in this cut: new catalogue services, fidelity epics, dev-mode, org learning path.

### v0.0.3 — Hosting day-1 gaps

**Theme:** what a CRM host needs next that is still thin or missing — cache, email, identity, metrics, edge, DNS/ACM polish, shared files.

| Include | Tickets |
|---------|---------|
| ElastiCache Redis (real-ish) | #61 |
| EFS (app shared files; not FSx specialty) | #62 (narrow to EFS) |
| SES (transactional / CRM mail) | #70 (SES; AppSync can stay stub or split out) |
| Cognito User Pools | #73 |
| CloudWatch Metrics + Alarms | #76 |
| Systems Manager | #77 |
| CloudFront (usable stub→partial) | #58 |
| WAFv2 associate + rule evaluation | #325, #326 (console stays #324 in 0.0.2) |
| PrivateLink polish | #106 |
| ECR `repositoryUri` docker push | #218 |
| Route 53 public / alias to APIGW | #56, #300 |
| ACM DNS validation automation | #339 |
| VPC polish docs / SG defaults | #51 |
| ALB/NLB remaining product tickets if not absorbed by #203 | #52, #53 |

### v0.1.0 — CRM org path

**Theme:** Transfer/SFTP → Lambda → S3 → ECS → RDS as a **fully working** learning/staging path; durable local env; one S3 brain.

| Include | Tickets |
|---------|---------|
| Org-scale epic + learning path | #90, #91 |
| Transfer native auth + inbound depth | #141 (and #322); connectors depth #314 as needed |
| Dev mode / persistence | #200, #288–291 |
| Unify S3 backends | #162 |
| Aurora failover / RDS depth beyond smoke | #225, #145 fidelity slice if not done in UI |
| AWS Backup | #101 |
| Cross-account resource policy smoke | #233 |
| CFN update rollback / deletion policy depth | #228 |
| Service-origin IAM condition keys | #223 |
| Pulumi + Ansible samples against local | #128, #129 |

### v0.1.1 — Delivery + enterprise attach

**Theme:** ship/migrate/observe like a hosting ops team; attach to customer networks honestly.

| Include | Tickets |
|---------|---------|
| CodePipeline + CodeBuild | #96, #97 |
| CodeDeploy depth (canary / console) | #340, #341 (+ #98 if open) |
| CloudTrail + Config | #78 |
| Organizations + quotas + resource groups | #79 |
| OpenSearch (CRM search / logs UI patterns) | #84 |
| DMS | #102 |
| Transit Gateway + Site-to-Site/Client VPN stubs | #104, #105 |
| DataSync stub (optional thin) | #103 |
| X-Ray stub | #80 |

### v0.1.2 — Account ops + real-account parity

**Theme:** FinOps chrome, SSO, mirror from real accounts, least-privilege tooling.

| Include | Tickets |
|---------|---------|
| IAM Identity Center | #110 |
| STS AssumeRole learning polish | #111 |
| Cost Explorer / Budgets / Billing chrome | #112 |
| RAM (+ AppConfig feature flags) | #113, #115 |
| Call log + least-privilege report | #194, #195 |
| Real-account mirror read + parity debt | #220, #299, #302 |
| Prowler / empty-read observability debt | #197, #198 |
| Service Catalog | #114 only if hosting marketplace needs it; else drop |

### v1.0.0 — Hosting-company ready

**Declaration cut**, not a ticket dump:

- Every **in-scope** row above is Working or Partial with honest docs + smokes (happy + authz sad).
- Console create/detail for shipped services (v0.0.2 epic closed or explicitly Debt).
- Org path #91 green end-to-end without sidecar lies (or documented remaining sidecar).
- Out-of-scope services either absent or chrome-only with empty states — never marketed as ready.
- Optional stretch only if pulled in earlier: rebrand (#305), fidelity epic leftovers (#180).

---

## Mapping from old v0.0.3 dump

Former “later catalogue” labels mixed hosting-critical work with niche stubs. This plan **keeps** hosting-critical items on `v0.0.3`–`v0.1.2` and **removes** release labels from out-of-v1 items (AI, niche IaC, exotic DB, analytics lakes, Lattice/GA/Firewall, Classic ELB, EKS, Batch dataplanes, MSK unless forced).

---

## How to use

1. Filter GitHub by label `v0.0.2` (etc.) for the cut.
2. When starting work on a card, set label to `$(cat docs/CURRENT_RELEASE)` only.
3. Do not invent `v0.2.x` until `v1.0.0` is cut — widen inside the cuts above or leave unlabelled.
