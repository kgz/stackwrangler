# Real-AWS parity — batch/2026-11-11 cheap set

Dual-side scripts (LocalEmu + real) for surfaces that stay under ~$0.50 and tear down cleanly.

```bash
./smokes/parity/aws-parity-cfn-path-scoped-role.sh   # #679
./smokes/parity/aws-parity-sg-prefixlist-description.sh  # #682
```

Shared harness: `smokes/lib/parity-sides.sh` (`AWSBOX_PARITY_SKIP_LOCAL` / `SKIP_REAL` / `REGION` / `KEEP`).

## Cost

| Script | Real resources | Residual if teardown OK | Residual if teardown fails |
|--------|----------------|-------------------------|----------------------------|
| `aws-parity-cfn-path-scoped-role.sh` | IAM roles/policies + CFN stacks | ~$0 | leftover `sw-psr-*` IAM / stacks |
| `aws-parity-sg-prefixlist-description.sh` | VPC + SG + managed prefix list | ~$0 | idle VPC/SG/PL (delete manually) |

No KMS, R53 hosted zones, NAT, or Fargate.

## Not dual-sided here (LocalEmu-only)

| Ticket | Why |
|--------|-----|
| #681 R53 Comment omit | Hosted zone ~$0.50/mo residual; covered by local `route53-smoke.sh` |
| #683/#684 ECR registry | LocalEmu registry + restart catalog |
| #685 entryPoint | Local docker `--entrypoint` |
| #686/#687 ECS HTTPS/SG | LocalEmu gateway TLS + SG exemptions |

## One side

`AWSBOX_PARITY_SKIP_LOCAL=1` · `AWSBOX_PARITY_SKIP_REAL=1` · `AWSBOX_PARITY_REGION` (default `ap-southeast-2`)
