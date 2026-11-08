# Changelog

Product cuts. GitHub Releases: [kgz/stackwrangler/releases](https://github.com/kgz/stackwrangler/releases). Versioning: [docs/versioning.md](https://github.com/kgz/stackwrangler/blob/main/docs/versioning.md).

## v0.0.4 — Accuracy (2026-11-09)

Depth on services already in the footprint: console create/detail/actions, ELBv2 ACM + health fidelity, ESM/stream correctness, and call-log / smoke coverage — so local behaviour matches AWS more closely than catalogue theatre.

### Console

- CloudWatch Logs create + stream/detail ([#352](https://github.com/kgz/stackwrangler/issues/352)); docs screenshots ([#608](https://github.com/kgz/stackwrangler/issues/608))
- Step Functions create/detail ([#533](https://github.com/kgz/stackwrangler/issues/533)) + Start execution ([#610](https://github.com/kgz/stackwrangler/issues/610))
- Secrets Manager store + detail ([#535](https://github.com/kgz/stackwrangler/issues/535))
- Kinesis create/detail/delete ([#539](https://github.com/kgz/stackwrangler/issues/539)) + put/retention/encryption/tags ([#615](https://github.com/kgz/stackwrangler/issues/615))
- API Gateway REST create/deploy ([#543](https://github.com/kgz/stackwrangler/issues/543)) + method integration picker ([#616](https://github.com/kgz/stackwrangler/issues/616))
- SNS create + topic detail ([#546](https://github.com/kgz/stackwrangler/issues/546)); delete + Create subscription ([#622](https://github.com/kgz/stackwrangler/issues/622))
- SQS create/detail/send ([#548](https://github.com/kgz/stackwrangler/issues/548)); receive/purge ([#627](https://github.com/kgz/stackwrangler/issues/627))
- EventBridge create + rule detail ([#552](https://github.com/kgz/stackwrangler/issues/552)); delete / edit / put-targets ([#630](https://github.com/kgz/stackwrangler/issues/630))

### Networking / ELBv2

- Listeners present ACM certificates ([#242](https://github.com/kgz/stackwrangler/issues/242))
- HTTP health checks honour path + matcher ([#243](https://github.com/kgz/stackwrangler/issues/243))
- ECS bridge TG health via host ports ([#247](https://github.com/kgz/stackwrangler/issues/247))
- ModifyListener / AddListenerCertificates ACM reload ([#594](https://github.com/kgz/stackwrangler/issues/594)); RemoveListenerCertificates / clear-default ([#628](https://github.com/kgz/stackwrangler/issues/628)); HTTPS ALB ACM smoke ([#629](https://github.com/kgz/stackwrangler/issues/629))
- `host_override` preserved across RegisterTargets ([#603](https://github.com/kgz/stackwrangler/issues/603))

### Compute / integration fidelity

- UpdateEventSourceMapping VT / MaximumConcurrency validation ([#367](https://github.com/kgz/stackwrangler/issues/367))
- Kinesis/DynamoDB stream ESM credential-refresh smoke ([#477](https://github.com/kgz/stackwrangler/issues/477))
- SQS FIFO ESM MaximumConcurrency message-group ordering ([#499](https://github.com/kgz/stackwrangler/issues/499))
- Per-workload API call log (CloudTrail-lite) ([#194](https://github.com/kgz/stackwrangler/issues/194)); ECS/CLI workload smoke ([#602](https://github.com/kgz/stackwrangler/issues/602))

### Platform / docs

- Batch LocalEmu resource gate (one stack at a time)
- Docs-site Search Console meta, `robots.txt`, sitemap, OG/JSON-LD
- KMS parity fixtures (`alias/sw-parity-fixture-*`) — reuse instead of stacking 7-day CMK residuals

### Install this cut

One `docker run … up` starts the **full account**: LocalEmu APIs, SeaweedFS S3, ECR registry, AWS profile `local` (CLI), and the **console web app** at <http://127.0.0.1:3000>. Prefer the version tag for this release; `:latest` tracks the newest cut.

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:v0.0.4
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:v0.0.4 up
```

Then: open the console · `aws --profile local s3 ls` · LocalEmu on `:4566`.

Optional thin host CLI (wraps the same `docker run`): [release asset `stackwrangler`](https://github.com/kgz/stackwrangler/releases/download/v0.0.4/stackwrangler).

## v0.0.3 — Trust (2026-11-08)

Authz that used to look green locally and lie: caller/RoleARN IAM on CFN, DynamoDB resource policies + SourceVpce, Simulate*, PermissionsBoundary / SNS subscribe condition keys, Lambda ECR pull, cross-account resource policies, service-origin ViaService, and deploy-as-role for Serverless.

### Identity & authz

- IAM `SimulateCustomPolicy` / `SimulatePrincipalPolicy` ([#517](https://github.com/kgz/stackwrangler/issues/517))
- `iam:PermissionsBoundary` on CreateRole / AttachRolePolicy ([#525](https://github.com/kgz/stackwrangler/issues/525))
- `sns:Protocol` / `sns:Endpoint` on Subscribe ([#518](https://github.com/kgz/stackwrangler/issues/518))
- DynamoDB table resource policies + `aws:SourceVpce` ([#516](https://github.com/kgz/stackwrangler/issues/516))
- Cross-account resource policy smoke (secrets / KMS / S3) ([#233](https://github.com/kgz/stackwrangler/issues/233))
- Service-origin keys (`kms:ViaService`, `aws:SourceArn` / `SourceAccount`, `iam:PassedToService`) ([#223](https://github.com/kgz/stackwrangler/issues/223))

### Data / compute

- DynamoDB index `aws:ResourceTag` inherits table tags ([#307](https://github.com/kgz/stackwrangler/issues/307))
- DynamoDB Transact/Batch IAM table-scoped policies ([#306](https://github.com/kgz/stackwrangler/issues/306))
- Lambda ECR image pull requires function-role `ecr:BatchGetImage` ([#219](https://github.com/kgz/stackwrangler/issues/219))

### IaC / platform

- CloudFormation resource ops run as caller or `RoleARN` through IAM ([#524](https://github.com/kgz/stackwrangler/issues/524); closes [#579](https://github.com/kgz/stackwrangler/issues/579))
- `stackwrangler sls --role-arn` deploy as the live principal ([#522](https://github.com/kgz/stackwrangler/issues/522))
- VPC Docker networks cleaned across `down`/`up` ([#479](https://github.com/kgz/stackwrangler/issues/479))

### Parity

- Local smokes for every Trust ticket; real-AWS harness `./smokes/parity/aws-parity-trust-v003.sh` (skips #479 LocalEmu-only; #233 needs a second account)

### Install this cut

One `docker run … up` starts the **full account**: LocalEmu APIs, SeaweedFS S3, ECR registry, AWS profile `local` (CLI), and the **console web app** at <http://127.0.0.1:3000>. Prefer the version tag for this release; `:latest` tracks the newest cut.

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:v0.0.3
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:v0.0.3 up
```

Then: open the console · `aws --profile local s3 ls` · LocalEmu on `:4566`.

Optional thin host CLI (wraps the same `docker run`): [release asset `stackwrangler`](https://github.com/kgz/stackwrangler/releases/download/v0.0.3/stackwrangler).

## v0.0.2 — Public (2026-11-07)

First public-ready cut: install without a git clone, stackwrangler rebrand, docs-site, and console/list depth on the hosting path.

### Install & platform

- Public Docker image path (`ghcr.io/kgz/stackwrangler`, cold-dir `install/stackwrangler`) — no monorepo checkout required ([#487](https://github.com/kgz/stackwrangler/issues/487))
- Rebrand awsbox → **stackwrangler** (CLI, compose, docs, design tokens) ([#305](https://github.com/kgz/stackwrangler/issues/305), [#421](https://github.com/kgz/stackwrangler/issues/421))
- Docs-site polish + GitHub Pages workflow ([#428](https://github.com/kgz/stackwrangler/issues/428))
- Linux docker CLI mount for LocalEmu VPC bridges (`STACKWRANGLER_DOCKER_CLI`)

### Identity / task roles

- ECS in-container task-role via `169.254.170.2` DNAT under compose ([#154](https://github.com/kgz/stackwrangler/issues/154))
- Bridge tasks on images **without** iptables still fetch creds via alpine netns sidecar ([#254](https://github.com/kgz/stackwrangler/issues/254))
- Lambda host maps only when the function has `VpcConfig` ([#187](https://github.com/kgz/stackwrangler/issues/187))

### Console (list / create where noted)

- CFN Create stack, update + change sets, StackSets chrome ([#93](https://github.com/kgz/stackwrangler/issues/93)–[#95](https://github.com/kgz/stackwrangler/issues/95))
- ECS/EC2 create + detail depth ([#146](https://github.com/kgz/stackwrangler/issues/146))
- RDS Create database (Postgres/MySQL) ([#145](https://github.com/kgz/stackwrangler/issues/145))
- API Gateway REST APIs list/detail ([#189](https://github.com/kgz/stackwrangler/issues/189))
- SQS, SNS, EventBridge, DynamoDB, Step Functions, Secrets, KMS, Kinesis lists ([#167](https://github.com/kgz/stackwrangler/issues/167)–[#178](https://github.com/kgz/stackwrangler/issues/178))
- Lambda **Deploy from zip**: styled `Upload .zip` control aligned with the name field (hotfix on `:v0.0.2` images)

### Fidelity / networking

- ECS same-host NLB VIP hairpin documented and smoked ([#181](https://github.com/kgz/stackwrangler/issues/181))

### Docs shots

- Console screenshots for RDS, REST APIs, SNS, SQS (+ interactions: RDS Create → SQL)

Create/detail depth Debts on list surfaces stay backlog (Accuracy). Aurora console/failover remains [#225](https://github.com/kgz/stackwrangler/issues/225).

### Install this cut

One `docker run … up` starts the **full account**: LocalEmu APIs, SeaweedFS S3, ECR registry, AWS profile `local` (CLI), and the **console web app** at <http://127.0.0.1:3000>. No separate console install. Prefer the version tag for this release; `:latest` tracks the newest cut.

```bash
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:v0.0.2
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:v0.0.2 up
```

Then: open the console · `aws --profile local s3 ls` · LocalEmu on `:4566`.

Digest pin (immutable): `ghcr.io/kgz/stackwrangler@sha256:fc20e100bf1146355b0ef38b9ff094c75658049b0cc485268fcf34fe1e30d831`.

Optional thin host CLI (wraps the same `docker run`): [release asset `stackwrangler`](https://github.com/kgz/stackwrangler/releases/download/v0.0.2/stackwrangler).

Terraform tour of the v0.0.2 surfaces (SQS/SNS/Events/Kinesis/DynamoDB/Secrets/KMS/SFN/ECS/REST/RDS + Lambda/S3): [`examples/terraform/v002-tour/`](https://github.com/kgz/stackwrangler/tree/main/examples/terraform/v002-tour).

Full reference: [docker-install.md](https://github.com/kgz/stackwrangler/blob/main/docs/docker-install.md) · [Getting started](/guide/getting-started)

## v0.0.1 — Baseline (2026-10-26)

First product cut (then named awsbox): API keys/usage plans, Transfer SSH keys + connectors, DynamoDB depth, EventBridge schedules, WAF/R53/ACM stubs, CodeDeploy, Serverless v3, REST Deny 403, VPC gateway endpoints.

See [v0.0.1 on GitHub](https://github.com/kgz/stackwrangler/releases/tag/v0.0.1).
