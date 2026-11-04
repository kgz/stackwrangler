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
      text: Completeness
      link: /guide/completeness
    - theme: alt
      text: GitHub
      link: https://github.com/kgz/stackwrangler

features:
  - title: Fully working bar
    details: Create → configure → traffic or data moves → you can see it in CLI and console. Control-plane stubs stay labelled stubs.
  - title: Authz that denies
    details: Workload principals and resource policies fail the same way as AWS when the policy is wrong — not a silent green.
  - title: Honest depth map
    details: Working, Partial, Sidecar, and Backlog are first-class. We do not market create-* as shipped.
  - title: Local → real AWS
    details: Stage on stackwrangler, then point the same tooling at a real account. Independent OSS, MIT license.
---

## Quick start

```bash
git clone https://github.com/kgz/stackwrangler.git
cd stackwrangler
./bin/stackwrangler up
./bin/stackwrangler console   # http://127.0.0.1:3000
aws --profile local s3 ls
```

See [Why](/guide/why), [Getting Started](/guide/getting-started), [Completeness](/guide/completeness), and [Concepts](/guide/concepts).
