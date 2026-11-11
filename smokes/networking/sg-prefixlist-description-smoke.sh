#!/usr/bin/env bash
# Prefix-list SG egress/ingress rule Description round-trips (#682).
# Authorize with PrefixListIds[].Description, then DescribeSecurityGroupRules
# and DescribeSecurityGroups must return it (Terraform perpetual-diff otherwise).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
DESC="S3 through the gateway endpoint"
VPC="" SG="" PL=""

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	set +e
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1
	[[ -n "$PL" ]] && aws ec2 delete-managed-prefix-list --prefix-list-id "$PL" >/dev/null 2>&1
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1
}
trap cleanup EXIT

VPC="$(aws ec2 create-vpc --cidr-block 10.82.0.0/16 --query 'Vpc.VpcId' --output text)"
SG="$(aws ec2 create-security-group \
	--group-name "awsbox-sg-pl-desc-${TS}" \
	--description "sg prefixlist description smoke" \
	--vpc-id "$VPC" \
	--query 'GroupId' --output text)"
PL="$(aws ec2 create-managed-prefix-list \
	--address-family IPv4 \
	--prefix-list-name "awsbox-sg-pl-desc-${TS}" \
	--max-entries 1 \
	--entries "Cidr=10.82.1.0/24,Description=fixture" \
	--query 'PrefixList.PrefixListId' --output text)"

# Drop the default allow-all egress so the authorize is the only egress rule.
aws ec2 revoke-security-group-egress --group-id "$SG" --protocol -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true

# JSON so Description may contain spaces (Terraform issue string).
IPPERM="$(PL="$PL" DESC="$DESC" python3 - <<'PY'
import json, os
print(json.dumps([{
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "PrefixListIds": [{
        "PrefixListId": os.environ["PL"],
        "Description": os.environ["DESC"],
    }],
}]))
PY
)"
aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions "$IPPERM" >/dev/null

PL="$PL" DESC="$DESC" SG="$SG" EP="$EP" REGION="$REGION" python3 - <<'PY'
import json, os, subprocess, sys

ep, region, sg, pl, desc = (
    os.environ["EP"],
    os.environ["REGION"],
    os.environ["SG"],
    os.environ["PL"],
    os.environ["DESC"],
)

def aws_json(*args):
    out = subprocess.check_output(
        ["aws", "--endpoint-url", ep, "--region", region, *args, "--output", "json"],
        text=True,
    )
    return json.loads(out)

rules = aws_json(
    "ec2",
    "describe-security-group-rules",
    "--filters",
    f"Name=group-id,Values={sg}",
)["SecurityGroupRules"]
egress = [r for r in rules if r.get("PrefixListId") == pl and r.get("IsEgress") is True]
if not egress:
    sys.exit(f"FAIL: no egress prefix-list rule for {pl}: {rules!r}")
got = egress[0].get("Description")
if got != desc:
    sys.exit(f"FAIL: DescribeSecurityGroupRules Description got {got!r} want {desc!r}")

groups = aws_json("ec2", "describe-security-groups", "--group-ids", sg)["SecurityGroups"][0]
found = None
for perm in groups.get("IpPermissionsEgress") or []:
    for entry in perm.get("PrefixListIds") or []:
        if entry.get("PrefixListId") == pl:
            found = entry.get("Description")
if found != desc:
    sys.exit(
        f"FAIL: DescribeSecurityGroups PrefixListIds Description got {found!r} want {desc!r}"
    )
print("egress ok")
PY

# Ingress path too (same moto code).
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions "$IPPERM" >/dev/null

PL="$PL" DESC="$DESC" SG="$SG" EP="$EP" REGION="$REGION" python3 - <<'PY'
import json, os, subprocess, sys

ep, region, sg, pl, desc = (
    os.environ["EP"],
    os.environ["REGION"],
    os.environ["SG"],
    os.environ["PL"],
    os.environ["DESC"],
)

def aws_json(*args):
    out = subprocess.check_output(
        ["aws", "--endpoint-url", ep, "--region", region, *args, "--output", "json"],
        text=True,
    )
    return json.loads(out)

rules = aws_json(
    "ec2",
    "describe-security-group-rules",
    "--filters",
    f"Name=group-id,Values={sg}",
)["SecurityGroupRules"]
ingress = [r for r in rules if r.get("PrefixListId") == pl and r.get("IsEgress") is False]
if not ingress:
    sys.exit(f"FAIL: no ingress prefix-list rule for {pl}: {rules!r}")
got = ingress[0].get("Description")
if got != desc:
    sys.exit(f"FAIL: ingress DescribeSecurityGroupRules Description got {got!r} want {desc!r}")
print("ingress ok")
PY

echo "OK: sg prefix-list rule Description (${SG} / ${PL})"
