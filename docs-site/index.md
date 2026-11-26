---
layout: home

hero:
  name: stackwrangler
  text: One local AWS-shaped account
  tagline: Real APIs, a grey-rose console on localhost, and IaC against profile local — then deploy the same shape to real AWS. Not affiliated with Amazon Web Services.
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Why
      link: /guide/why
    - theme: alt
      text: Compare
      link: /guide/compare/
    - theme: alt
      text: Use cases
      link: /guide/use-cases/
    - theme: alt
      text: GitHub
      link: https://github.com/kgz/stackwrangler
  badge:
    text: v0.1.2
    link: /guide/completeness
    type: tip

features:
  - title: Not default-allow
    details: Most local stacks let bad IAM “succeed.” We run IAM_ENFORCEMENT=1 — AccessDenied when the policy is wrong, like AWS.
  - title: Authz that denies
    details: Workload principals and resource policies fail the same way as AWS — smokes and parity on deny paths, not a silent green.
  - title: Fully working bar
    details: Create → configure → traffic or data moves → you can see it in CLI and console. Control-plane stubs stay labelled stubs.
  - title: Honest depth map
    details: Working, Partial, Sidecar, and Backlog are first-class. We do not market create-* as shipped.
  - title: Local → real AWS
    details: Stage on stackwrangler, then point the same tooling at a real account. Independent OSS, MIT license.
  - title: One account surface
    details: Console, aws --profile local, and Terraform / CDK / SAM / Pulumi talk to the same local account.
---

<div class="sw-home-section">

## Quick example

Bring the account up, open the console, talk to it with the AWS CLI:

::: code-group

```bash [Bring up]
mkdir -p ~/.stackwrangler ~/.aws
docker pull ghcr.io/kgz/stackwrangler:latest
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.stackwrangler:/data" \
  -v "$HOME/.aws:/root/.aws" \
  ghcr.io/kgz/stackwrangler:latest up
# → http://127.0.0.1:3000
```

```bash [CLI]
aws --profile local s3 ls
aws --profile local \
  --endpoint-url http://127.0.0.1:4566 \
  lambda list-functions
```

:::

::: tip Not default-allow
Most free emulators **default-allow** IAM. stackwrangler enforces (`IAM_ENFORCEMENT=1`) so bad policies fail locally — then harden with patches, console, and parity checks. **LocalEmu** is the engine; **stackwrangler** is the product. [Compare](/guide/compare/) · [Use cases](/guide/use-cases/) · not Cloudflare Wrangler.
:::

### Built for agents and scanners

| Hook | Why it matters |
|------|----------------|
| **AI coding agents** (Cursor, Claude Code, …) | Zero-credential local sandbox — agents can `tofu apply` / CLI against profile `local` and catch **AccessDenied** hops before staging. |
| **Security & diagramming** | Point Prowler, Steampipe, and AWS diagrammers at `127.0.0.1:4566` without requesting read-all production IAM keys. |

### Console strip

Screenshots from a **local** stack after `docker … stackwrangler:latest up` (or repo checkout: `./bin/stackwrangler up`) — not the AWS Management Console:

<div class="sw-shot-strip">
  <figure>
    <img src="/assets/console/home-s3-buckets.png" alt="S3 buckets in the local console" />
    <figcaption>S3 — LocalEmu org-path buckets UI</figcaption>
  </figure>
  <figure>
    <img src="/assets/console/lambda-functions.png" alt="Lambda functions list" />
    <figcaption>Lambda — LocalEmu functions</figcaption>
  </figure>
  <figure>
    <img src="/assets/console/ecs-clusters.png" alt="ECS clusters list" />
    <figcaption>ECS — clusters / services</figcaption>
  </figure>
</div>

More shots: [Console tour](/guide/console-tour).

## Why stackwrangler?

<div class="sw-why-grid">
  <div class="sw-why-card">
    <strong>Not default-allow</strong>
    <p>Missing IAM, wrong trust, or a hop that never moves data fails locally the same way it would on real AWS — AccessDenied on the laptop, not in prod.</p>
  </div>
  <div class="sw-why-card">
    <strong>Same tooling path</strong>
    <p>Stage with CLI, console, and IaC against profile <code>local</code>, then point the same shape at a real account.</p>
  </div>
  <div class="sw-why-card">
    <strong>Org-path first</strong>
    <p>Prefer deepening Transfer → Lambda → S3 → ECS → RDS over catalogue width of stub APIs.</p>
  </div>
  <div class="sw-why-card">
    <strong>Independent OSS</strong>
    <p>MIT-licensed. Not affiliated with Amazon Web Services. Not a hosted AWS substitute.</p>
  </div>
</div>

## How it compares

Compact slice — full write-ups under [Compare](/guide/compare/):

| | **stackwrangler** | **AWS Emulator** | **LocalStack** |
|--|-------------------|------------------|----------------|
| **IAM at apply time** | `IAM_ENFORCEMENT=1` — wrong workload / resource policies **AccessDenied** | Schema / apply shape; **does not evaluate IAM** → false green on staging IAM bugs | Community/history of weak IAM; Pro tiers for depth |
| **Local console UI** | Grey-rose console on `127.0.0.1:3000`, same account as CLI | No product console in the same sense | Console varies by product tier |
| **Depth strategy** | Org-path depth + honest Working / Partial / Stub | Broad API surface for shape checks | Catalogue width; Pro-gated depth |

Named pages: [vs AWS Emulator](/guide/compare/vs-aws-emulator) · [vs LocalStack](/guide/compare/vs-localstack) · [vs LocalEmu](/guide/compare/vs-localemu).

Ready? [Getting Started](/guide/getting-started) · [Compare](/guide/compare/) · [Architecture](/guide/architecture) · [Fidelity](/guide/fidelity) · [Use cases](/guide/use-cases/) · [Completeness](/guide/completeness)

Docs also run locally: `cd docs-site && pnpm install && pnpm dev` → [docs-site README](https://github.com/kgz/stackwrangler/blob/main/docs-site/README.md). Hosted: [stackwrangler.dev](https://stackwrangler.dev/).

</div>
