# Slice: waf (#55)

CFN shape for `AWS::WAFv2::WebACL` (rate + managed-style rule) and `AWS::WAFv2::WebACLAssociation` to a REST API stage, with the ACL ARN in SSM (`${ssm:...}` consumers).

**Smoke:** `./bin/waf-smoke.sh` (CLI deploy of this shape against LocalEmu). Rule evaluation is not real edge WAF — see [docs/waf.md](../../../../docs/waf.md).

Parent fixture `examples/serverless-v3-rest/` is owned by #185; this slice runs alone via the smoke.
