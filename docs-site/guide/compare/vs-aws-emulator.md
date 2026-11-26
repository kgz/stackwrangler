# vs AWS Emulator

**AWS Emulator** (AWS Builder Center / official local emulator direction) is strong for **API schema and apply shape** — Terraform / CDK can often create resources against a local endpoint.

It is **not** a substitute for runtime IAM evaluation. Missing or wrong workload roles, trust, and resource policies can still look green locally and only fail in staging.

## Choose AWS Emulator if

- You need official schema coverage / Builder Center integration first
- You will catch IAM elsewhere (staging account, Checkov-style static checks, or a separate enforcement sandbox)

## Choose stackwrangler if

- Your pain is **false-green IAM** — agents and humans `apply` locally and need **AccessDenied** when the principal hop is wrong
- You want CLI + grey-rose **console** + IaC on one local account with `IAM_ENFORCEMENT=1`
- You care about deny-path smokes / parity, not only `create-*`

## IAM Mock Trap (why this page exists)

Static policy linters check **shape**. AWS Emulator-style schema emulators check **API shape**. Neither evaluates **principal → action → resource** the way AWS does at call time.

stackwrangler’s bar: LocalEmu with **`IAM_ENFORCEMENT=1`**, then patches / console / smokes so a green `tofu apply` is not false confidence before CTO / staging.

## Spine

Same local AWS-shaped account job — **with IAM that denies**. See [Compare](./) · [vs LocalStack](./vs-localstack) · [Use case — OpenTofu → Expo + IAM](../use-cases/opentofu-expo-iam).

Not affiliated with Amazon Web Services.
