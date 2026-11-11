#!/usr/bin/env bash
# Dual-side: SG PrefixListIds[].Description round-trips (#682).
# LocalEmu + real AWS. Short-lived VPC/SG/prefix-list; teardown on EXIT.
# Usage: ./smokes/parity/aws-parity-sg-prefixlist-description.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
#
# Cost (real): EC2 VPC + SG + customer-managed prefix list — $0 if torn down.
# Residual if teardown fails: idle VPC/SG/PL (no hourly VPC charge; clean up manually).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/parity-sides.sh"

KEEP="${AWSBOX_PARITY_KEEP:-0}"
TS="$(date +%s)"
DESC="S3 through the gateway endpoint"

run_side() {
	local label="$1"
	local vpc="" sg="" pl=""
	local ipperm rules_json groups_json got_e got_i found
	local octet

	teardown() {
		[[ "$KEEP" == "1" ]] && {
			echo "KEEP=1 — left ${label} vpc=${vpc} sg=${sg} pl=${pl}"
			return 0
		}
		echo "==> ${label}: teardown"
		[[ -n "$sg" ]] && aws_cli ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || true
		[[ -n "$pl" ]] && aws_cli ec2 delete-managed-prefix-list --prefix-list-id "$pl" >/dev/null 2>&1 || true
		[[ -n "$vpc" ]] && aws_cli ec2 delete-vpc --vpc-id "$vpc" >/dev/null 2>&1 || true
	}

	octet=$((80 + ${#label}))
	echo "==> ${label}: create vpc + sg + managed prefix list"
	vpc="$(aws_cli ec2 create-vpc --cidr-block "10.${octet}.0.0/16" \
		--query 'Vpc.VpcId' --output text)"
	sg="$(aws_cli ec2 create-security-group \
		--group-name "sw-parity-sg-pl-${label}-${TS}" \
		--description "parity sg prefixlist description" \
		--vpc-id "$vpc" \
		--query 'GroupId' --output text)"
	pl="$(aws_cli ec2 create-managed-prefix-list \
		--address-family IPv4 \
		--prefix-list-name "sw-parity-sg-pl-${label}-${TS}" \
		--max-entries 1 \
		--entries "Cidr=10.82.1.0/24,Description=fixture" \
		--query 'PrefixList.PrefixListId' --output text)"

	aws_cli ec2 revoke-security-group-egress --group-id "$sg" --protocol -1 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true

	ipperm="$(PL="$pl" DESC="$DESC" python3 - <<'PY'
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
	aws_cli ec2 authorize-security-group-egress --group-id "$sg" --ip-permissions "$ipperm" >/dev/null
	aws_cli ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "$ipperm" >/dev/null

	local rules_file groups_file
	rules_file="$(mktemp)"
	groups_file="$(mktemp)"
	aws_cli ec2 describe-security-group-rules \
		--filters "Name=group-id,Values=${sg}" --output json >"$rules_file"
	got_e="$(RULES_FILE="$rules_file" PL="$pl" python3 - <<'PY'
import json, os
rules = json.load(open(os.environ["RULES_FILE"]))["SecurityGroupRules"]
pl = os.environ["PL"]
egress = [r for r in rules if r.get("PrefixListId") == pl and r.get("IsEgress") is True]
if not egress:
    raise SystemExit("missing-egress")
print(egress[0].get("Description") or "")
PY
)"
	[[ "$got_e" == "$DESC" ]] || {
		echo "FAIL (${label}): egress DescribeSecurityGroupRules Description got '${got_e}' want '${DESC}'" >&2
		rm -f "$rules_file" "$groups_file"
		teardown
		return 1
	}

	got_i="$(RULES_FILE="$rules_file" PL="$pl" python3 - <<'PY'
import json, os
rules = json.load(open(os.environ["RULES_FILE"]))["SecurityGroupRules"]
pl = os.environ["PL"]
ingress = [r for r in rules if r.get("PrefixListId") == pl and r.get("IsEgress") is False]
if not ingress:
    raise SystemExit("missing-ingress")
print(ingress[0].get("Description") or "")
PY
)"
	[[ "$got_i" == "$DESC" ]] || {
		echo "FAIL (${label}): ingress DescribeSecurityGroupRules Description got '${got_i}' want '${DESC}'" >&2
		rm -f "$rules_file" "$groups_file"
		teardown
		return 1
	}

	aws_cli ec2 describe-security-groups --group-ids "$sg" --output json >"$groups_file"
	found="$(GROUPS_FILE="$groups_file" PL="$pl" python3 - <<'PY'
import json, os
g = json.load(open(os.environ["GROUPS_FILE"]))["SecurityGroups"][0]
pl = os.environ["PL"]
for perm in g.get("IpPermissionsEgress") or []:
    for entry in perm.get("PrefixListIds") or []:
        if entry.get("PrefixListId") == pl:
            print(entry.get("Description") or "")
            raise SystemExit
print("")
PY
)"
	rm -f "$rules_file" "$groups_file"
	[[ "$found" == "$DESC" ]] || {
		echo "FAIL (${label}): DescribeSecurityGroups PrefixListIds Description got '${found}' want '${DESC}'" >&2
		teardown
		return 1
	}

	echo "OK (${label}): SG prefix-list Description round-trip (${sg} / ${pl})"
	teardown
}

parity_run_sides
echo "OK: sg prefix-list Description parity complete (ts=${TS})"
