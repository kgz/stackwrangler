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
      text: Vision
      link: /guide/vision
    - theme: alt
      text: GitHub
      link: https://github.com/kgz/stackwrangler
  badge:
    text: v0.0.2 Public
    link: /guide/completeness
    type: tip

features:
  - title: Fully working bar
    details: Create → configure → traffic or data moves → you can see it in CLI and console. Control-plane stubs stay labelled stubs.
  - title: Authz that denies
    details: Workload principals and resource policies fail the same way as AWS when the policy is wrong — not a silent green.
  - title: Honest depth map
    details: Working, Partial, Sidecar, and Backlog are first-class. We do not market create-* as shipped.
  - title: Local → real AWS
    details: Stage on stackwrangler, then point the same tooling at a real account. Independent OSS, MIT license.
  - title: One account surface
    details: Console, aws --profile local, and Terraform / CDK / SAM / Pulumi talk to the same local account.
  - title: Sidecars when needed
    details: Prefer a real data plane (Postgres, SFTP listener) over pretending the emulator can do everything.
---

<div class="sw-home-section">

## Quick example

Bring the account up, open the console, talk to it with the AWS CLI:

::: code-group

```bash [Bring up]
git clone https://github.com/kgz/stackwrangler.git
cd stackwrangler
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
```

```bash [CLI]
aws --profile local s3 ls
aws --profile local \
  --endpoint-url http://127.0.0.1:4566 \
  lambda list-functions
```

:::

::: tip LocalEmu vs stackwrangler
**LocalEmu** is the emulator (`:4566`, `IAM_ENFORCEMENT=1`). **stackwrangler** is the product — compose, profile `local`, grey-rose console, smokes, and honesty about depth. Not Cloudflare Wrangler.
:::

### Console strip

Screenshots from a **local** stack after `./bin/stackwrangler up` (not the AWS Management Console):

<div class="sw-shot-strip">
  <figure>
    <img src="/assets/console/home-s3-buckets.png" alt="S3 buckets in the local console" />
    <figcaption>S3 — SeaweedFS buckets UI</figcaption>
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
    <strong>No false greens</strong>
    <p>Missing IAM, wrong trust, or a hop that never moves data fails locally the same way it would on real AWS.</p>
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

Ready? [Getting Started](/guide/getting-started) · [Vision](/guide/vision) · [Completeness](/guide/completeness)

Docs also run locally: `cd docs-site && pnpm install && pnpm dev` → [docs-site README](https://github.com/kgz/stackwrangler/blob/main/docs-site/README.md). Hosted target: [kgz.github.io/stackwrangler](https://kgz.github.io/stackwrangler/).

</div>
