# Real AWS parity — v0.0.8 (escaped local fidelity)

Reusable dual-target checks for the **AWS-behaviour** bugs in the v0.0.8 cut. LocalEmu-only platform tickets stay on their local smokes.

```bash
# Local only
./bin/parity run --suite v008 --target local

# Real AWS (needs --approve-cost; ≤ ~$0.05 if torn down within ~15m)
./bin/parity run --suite v008 --target both --approve-cost

# Or the thin wrapper:
./smokes/parity/aws-parity-v008.sh --target both --approve-cost
```

## Checks

| Id | Issues | Cost tier | Est (real, ~15m) | Residual |
|----|--------|-----------|------------------|----------|
| `ecs-awsvpc-same-port` | #769 | low | ~$0.02 (2×Fargate 0.25vCPU) | none if torn down |
| `elbv2-sg-member` | #768 | low | ~$0.02 (ALB + 1×Fargate) | none if torn down |

Shared harness: `smokes/parity/lib/parity-common.sh`. Region: `AWSBOX_PARITY_REGION` / `STACKWRANGLER_PARITY_REGION` (default `ap-southeast-2`). Real needs `ecsTaskExecutionRole`.

## Local-only (no real-AWS dual assert)

| Issue | Why skipped on real |
|-------|---------------------|
| #747 / #753 / #754 / #770 | Dev-mode / LocalEmu restore |
| #749 / #750 | CLI / Docker edge install path |
| #764 / #771 | Local CA / PHP/Java inject (AWS does not inject these) |
| #765 | Real RDS TLS certs exist; creating an instance for SAN parity is over the cost bar |

Use the matching `smokes/**` scripts for those.

## Cost cap

Keep the suite under **$0.50** worst case: short-lived ALB + Fargate only, no NAT, no RDS, no new CMK. Teardown is the EXIT trap in each check (`AWSBOX_PARITY_KEEP=1` / `--keep` skips it).
