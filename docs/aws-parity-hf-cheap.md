# Real-AWS parity — high-focus cheap set

Short-lived create → assert → delete for HF tickets that stay **free-tier / cents** when teardown succeeds.

```bash
./smokes/parity/aws-parity-hf-cheap.sh
```

| Side | What runs |
|------|-----------|
| Local | `dynamodb-depth-smoke` · `events-schedule-smoke` · `apigw-rest-smoke` · `apigw-usage-plan-smoke` · `vpc-egress-smoke` |
| Real | Focused asserts for #296 · #297 · #190 · #294 · #230 (gateway VPCE only) |

**Cost:** Lambda + API Gateway + DynamoDB on-demand + EventBridge + empty VPC + **S3 gateway VPCE ($0)**. No KMS CMK, NAT, EIP, Transfer, WAF WebACL, or Route 53 hosted zone.  
**Region (real):** `AWSBOX_PARITY_REGION` (default `ap-southeast-2`)  
**Keep:** `AWSBOX_PARITY_KEEP=1`  
**One side:** `AWSBOX_PARITY_SKIP_LOCAL=1` · `AWSBOX_PARITY_SKIP_REAL=1`  
**Skip schedule wait:** `AWSBOX_PARITY_SKIP_SCHEDULE=1`  
**Schedule-only retest:** `AWSBOX_PARITY_SCHEDULE_ONLY=1`  
**Schedule knobs:** `AWSBOX_SCHEDULE_WINDOW` (default 300s) · `AWSBOX_SCHEDULE_DRAIN` (default 75s after disable) · `AWSBOX_SCHEDULE_QUIET` (default 90s)

Ask before running the **real** side (repo cost rule). Local-only is fine anytime the stack is up.

## Local credential isolation

Local smokes source `smokes/lib/local-emu-env.sh`, which:

- maps `STACKWRANGLER_*` → `AWSBOX_*`
- points credentials at an empty/temp file (not `~/.aws`)
- disables instance metadata
- refuses non-loopback `AWSBOX_IAM_ENDPOINT`
- refuses access keys that look like real IAM keys (`AKIA…` / `ASIA…`)

Real side of this script sets `AWSBOX_ALLOW_REAL_AWS=1` and still requires explicit approval per the repo cost rule.


## Covered on real AWS

| Ticket | Asserts | Not asserted on real (still local) |
|--------|---------|-------------------------------------|
| **#296** DynamoDB depth | CFN table + GSI + TTL enabled; conditional put deny; GSI query | TTL item sweep (~48h on AWS); index/table ARN IAM matrix; TransactWriteItems |
| **#297** EventBridge schedule | `rate(1 minute)` ≥2 Lambda invocations; quiet after `disable-rule` (real zip is a tick-only handler — slice SDK code stays local) | cron expression; no-permission target never invokes; real TTL/DDB sweep body |
| **#190** REST Deny → 403 | no token → 401; `Bearer bad` → 403; `Bearer good` → 200 | custom domain / base-path mappings |
| **#294** API keys + usage plans | open route; missing key 403; valid key 200; disabled key 403 | throttle 429; quota 429; Lambda mint + `apigateway:POST` IAM; `apiKeySource=AUTHORIZER` |
| **#230** VPC GW endpoints | create/describe/delete **S3 gateway** VPCE on a throwaway VPC | Lambda private egress, prefix-list routes, peering DNAT, ECS bridge (local `vpc-egress-smoke`) |

## Skipped gaps (not run on real — cost or domain)

| Ticket | Why skipped on real AWS |
|--------|-------------------------|
| **#55** WAFv2 | WebACL + rules are monthly-class pricing even when short-lived |
| **#56** Route 53 | Public hosted zone ≈ **$0.50/mo** |
| **#74** ACM | Public cert is $0 but needs a real DNS zone you control; no useful assert without #56 |
| **#83** Batch / Beanstalk / App Runner / ASG | Real compute / stub-only locally |
| **#98** CodeDeploy | Service free; blue/green ECS or Lambda canary target stack is not cents |
| **#141** Transfer native SFTP | Transfer endpoint ≈ **$0.30/hr** |
| **#185** Serverless Framework v3 | Full `serverless deploy` recreates a larger free-tier stack; covered by local smoke + the cheaper surfaces above |
| **#295** Transfer connectors | Needs Transfer / remote SFTP path; not cents |
| **#230** (egress proof) | Full “no default route” Lambda/ECS path stays local; real side is gateway VPCE control plane only |

Debt tickets that stay local-only by design (console, reporting, etc.) are unchanged — see each parent issue.
