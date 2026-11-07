# Changelog

Product cuts. GitHub Releases: [kgz/stackwrangler/releases](https://github.com/kgz/stackwrangler/releases). Versioning: [docs/versioning.md](https://github.com/kgz/stackwrangler/blob/main/docs/versioning.md).

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

### Fidelity / networking

- ECS same-host NLB VIP hairpin documented and smoked ([#181](https://github.com/kgz/stackwrangler/issues/181))

### Docs shots

- Console screenshots for RDS, REST APIs, SNS, SQS (+ interactions: RDS Create → SQL)

Create/detail depth Debts on list surfaces stay backlog (Accuracy). Aurora console/failover remains [#225](https://github.com/kgz/stackwrangler/issues/225).

**Install:** [docker-install.md](https://github.com/kgz/stackwrangler/blob/main/docs/docker-install.md) · [Getting started](/guide/getting-started)

## v0.0.1 — Baseline (2026-10-26)

First product cut (then named awsbox): API keys/usage plans, Transfer SSH keys + connectors, DynamoDB depth, EventBridge schedules, WAF/R53/ACM stubs, CodeDeploy, Serverless v3, REST Deny 403, VPC gateway endpoints.

See [v0.0.1 on GitHub](https://github.com/kgz/stackwrangler/releases/tag/v0.0.1).
