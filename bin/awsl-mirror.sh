#!/usr/bin/env bash
# awsl mirror | awsl apply — topology fixtures (#216).
# mirror never calls AWS. apply talks only to a loopback LocalEmu endpoint.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
	cat <<EOF
Usage:
  awsl mirror dry-run [--out <dir>]
  awsl mirror --out <dir>
  awsl apply <fixture.json>

mirror lists the read APIs a later real-account pass would call. It does not
call AWS and does not write a fixture. --out inside this repo is refused
unless that path is gitignored.

apply creates VPC, subnet, and security group resources from a synthetic
fixture on AWSBOX_IAM_ENDPOINT (default http://127.0.0.1:4566). The endpoint
must be loopback. Ids are pinned with the tag awsbox:resource-id, which
LocalEmu honors after localemu-patches/init/start.d/20-mirror-resource-ids.py
is loaded (recreate the emulator).

See docs/mirror.md.
EOF
}

assert_out_path() {
	local dest="$1"
	local abs root
	abs="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$dest")"
	root="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ROOT")"
	case "$abs" in
		"$root" | "$root"/*)
			if git -C "$ROOT" check-ignore -q -- "$abs"; then
				return 0
			fi
			echo "refusing to write a fixture inside the repo (not gitignored): $abs" >&2
			exit 1
			;;
	esac
}

dry_run_text() {
	cat <<'EOF'
mirror dry-run: no AWS calls.

## read-only
  ec2:DescribeVpcs
  ec2:DescribeSubnets
  ec2:DescribeRouteTables
  ec2:DescribeVpcPeeringConnections
  ec2:DescribeInternetGateways
  ec2:DescribeNatGateways
  ec2:DescribeVpcEndpoints
  ec2:DescribeSecurityGroups
  elasticloadbalancing:DescribeLoadBalancers
  elbv2:DescribeLoadBalancers
  elbv2:DescribeListeners
  elbv2:DescribeTargetGroups
  elbv2:DescribeRules
  route53:ListHostedZones
  route53:ListResourceRecordSets
  ecs:ListClusters
  ecs:DescribeClusters
  ecs:ListServices
  ecs:DescribeServices
  ecs:ListTaskDefinitions
  ecs:DescribeTaskDefinition
  iam:ListRoles
  iam:GetRole
  iam:ListRolePolicies
  iam:GetRolePolicy
  iam:ListAttachedRolePolicies
  iam:GetPolicy
  iam:GetPolicyVersion
  iam:ListOpenIDConnectProviders
  iam:GetOpenIDConnectProvider
  ssm:DescribeParameters
  secretsmanager:ListSecrets
  lambda:ListFunctions
  lambda:GetFunction
  apigateway:GetRestApis
  apigateway:GetResources

## excluded
  secretsmanager:GetSecretValue
  secretsmanager:BatchGetSecretValue
  ssm:GetParameter
  ssm:GetParameters
  ssm:GetParametersByPath
  ecs:DescribeTaskDefinition environment and secrets
  lambda:GetFunction environment

Real-account reads are not implemented. Apply the synthetic fixture:
  ./bin/awsl apply testdata/mirror/synthetic-vpc.json
EOF
}

cmd_mirror() {
	local out="" dry=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			dry-run | --dry-run)
				dry=1
				shift
				;;
			--out)
				out="${2:-}"
				if [[ -z "$out" ]]; then
					echo "mirror --out needs a path" >&2
					exit 2
				fi
				shift 2
				;;
			-h | --help)
				usage
				exit 0
				;;
			*)
				echo "unknown arg: $1" >&2
				usage >&2
				exit 2
				;;
		esac
	done
	if [[ -n "$out" ]]; then
		assert_out_path "$out"
	fi
	if [[ "$dry" -eq 1 ]]; then
		dry_run_text
		exit 0
	fi
	echo "refusing to mirror: real-account read path is not implemented." >&2
	echo "no AWS calls were made." >&2
	if [[ -n "$out" ]]; then
		echo "out=$out is allowed, but nothing was written." >&2
	fi
	echo "list the intended reads: ./bin/awsl mirror dry-run" >&2
	echo "apply a synthetic fixture: ./bin/awsl apply testdata/mirror/synthetic-vpc.json" >&2
	exit 2
}

cmd_apply() {
	local fixture="${1:-}"
	if [[ -z "$fixture" || ! -f "$fixture" ]]; then
		echo "usage: awsl apply <fixture.json>" >&2
		exit 2
	fi
	if [[ $# -gt 1 ]]; then
		echo "unexpected arg: $2" >&2
		exit 2
	fi
	local ep="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
	AWSBOX_MIRROR_ENDPOINT="$ep" \
		AWSBOX_MIRROR_KEY="${AWSBOX_ACCESS_KEY:-awsbox}" \
		AWSBOX_MIRROR_SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}" \
		python3 - "$fixture" <<'PY'
import ipaddress
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlparse

fixture_path = sys.argv[1]
endpoint = os.environ["AWSBOX_MIRROR_ENDPOINT"]
TAG = "awsbox:resource-id"
FORBIDDEN_KEYS = {
    "secret",
    "secretstring",
    "password",
    "environment",
    "valuefrom",
    "accesskeyid",
    "secretaccesskey",
}
ID_RE = {
    "vpc": re.compile(r"^vpc-[0-9a-f]{8,17}$"),
    "subnet": re.compile(r"^subnet-[0-9a-f]{8,17}$"),
    "sg": re.compile(r"^sg-[0-9a-f]{8,17}$"),
}


def refuse_endpoint(url: str) -> None:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    local = host in {"127.0.0.1", "localhost", "::1", "awsbox.localhost"} or host.endswith(
        ".localhost"
    )
    if parsed.scheme == "http" and local:
        return
    sys.stderr.write(f"refusing apply: endpoint is not local ({url})\n")
    raise SystemExit(1)


def reject_secrets(node) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                sys.stderr.write(f"refusing fixture field {key}\n")
                raise SystemExit(1)
            reject_secrets(value)
        return
    if isinstance(node, list):
        for item in node:
            reject_secrets(item)


def require_keys(node, allowed, required, label):
    extra = set(node) - allowed
    missing = required - set(node)
    if extra or missing:
        sys.stderr.write(
            f"invalid {label}: missing={sorted(missing)} extra={sorted(extra)}\n"
        )
        raise SystemExit(1)


def cidr_ok(value: str) -> str:
    try:
        network = ipaddress.IPv4Network(value, strict=True)
    except ValueError:
        sys.stderr.write(f"invalid cidr: {value}\n")
        raise SystemExit(1)
    return str(network)


refuse_endpoint(endpoint)

with open(fixture_path, encoding="utf-8") as handle:
    doc = json.load(handle)

reject_secrets(doc)
require_keys(doc, {"schema", "region", "resources"}, {"schema", "region", "resources"}, "fixture")
if doc["schema"] != "awsl.mirror/v1":
    sys.stderr.write(f"unsupported schema: {doc['schema']}\n")
    raise SystemExit(1)

region = str(doc["region"])
resources = doc["resources"]
require_keys(
    resources,
    {"vpcs", "subnets", "securityGroups"},
    {"vpcs", "subnets", "securityGroups"},
    "resources",
)

vpcs = resources["vpcs"]
subnets = resources["subnets"]
groups = resources["securityGroups"]
if not isinstance(vpcs, list) or not isinstance(subnets, list) or not isinstance(groups, list):
    sys.stderr.write("resources arrays must be lists\n")
    raise SystemExit(1)


def aws(*args, check=True):
    cmd = [
        "aws",
        "--endpoint-url",
        endpoint,
        "--region",
        region,
        *args,
    ]
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", "/tmp"),
        "AWS_ACCESS_KEY_ID": os.environ["AWSBOX_MIRROR_KEY"],
        "AWS_SECRET_ACCESS_KEY": os.environ["AWSBOX_MIRROR_SECRET"],
        "AWS_DEFAULT_REGION": region,
        "AWS_EC2_METADATA_DISABLED": "true",
        "AWS_PAGER": "",
    }
    result = subprocess.run(cmd, env=env, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode or 1)
    return result


def tag_spec(resource_type: str, resource_id: str, name):
    tags = [{"Key": TAG, "Value": resource_id}]
    if name:
        tags.append({"Key": "Name", "Value": name})
    return [{"ResourceType": resource_type, "Tags": tags}]


def missing(result) -> bool:
    blob = (result.stderr or "") + (result.stdout or "")
    return result.returncode != 0 and "NotFound" in blob


def expect_id(kind: str, value: str) -> str:
    if not ID_RE[kind].match(value):
        sys.stderr.write(f"invalid {kind} id: {value}\n")
        raise SystemExit(1)
    return value


def apply_vpc(vpc) -> None:
    require_keys(vpc, {"id", "cidr", "name"}, {"id", "cidr"}, "vpc")
    vpc_id = expect_id("vpc", vpc["id"])
    cidr = cidr_ok(vpc["cidr"])
    name = vpc.get("name")
    found = aws(
        "ec2",
        "describe-vpcs",
        "--vpc-ids",
        vpc_id,
        "--output",
        "json",
        check=False,
    )
    if found.returncode == 0:
        body = json.loads(found.stdout)
        got = body["Vpcs"][0]["CidrBlock"]
        if got != cidr:
            sys.stderr.write(f"{vpc_id} cidr is {got}, fixture wants {cidr}\n")
            raise SystemExit(1)
        print(f"vpc {vpc_id} {cidr} exists")
        return
    if not missing(found):
        sys.stderr.write(found.stderr)
        raise SystemExit(found.returncode or 1)
    created = aws(
        "ec2",
        "create-vpc",
        "--cli-input-json",
        json.dumps(
            {
                "CidrBlock": cidr,
                "TagSpecifications": tag_spec("vpc", vpc_id, name),
            }
        ),
        "--query",
        "Vpc.VpcId",
        "--output",
        "text",
    )
    got_id = created.stdout.strip()
    if got_id != vpc_id:
        sys.stderr.write(
            f"created {got_id} but fixture id is {vpc_id}\n"
            "LocalEmu is missing localemu-patches/init/start.d/20-mirror-resource-ids.py\n"
            "Recreate the emulator so the start.d hook loads.\n"
        )
        raise SystemExit(1)
    print(f"vpc {vpc_id} {cidr} created")


def apply_subnet(subnet) -> None:
    require_keys(
        subnet,
        {"id", "vpcId", "cidr", "availabilityZone", "name"},
        {"id", "vpcId", "cidr", "availabilityZone"},
        "subnet",
    )
    subnet_id = expect_id("subnet", subnet["id"])
    vpc_id = expect_id("vpc", subnet["vpcId"])
    cidr = cidr_ok(subnet["cidr"])
    az = str(subnet["availabilityZone"])
    name = subnet.get("name")
    found = aws(
        "ec2",
        "describe-subnets",
        "--subnet-ids",
        subnet_id,
        "--output",
        "json",
        check=False,
    )
    if found.returncode == 0:
        body = json.loads(found.stdout)
        row = body["Subnets"][0]
        if row["CidrBlock"] != cidr or row["VpcId"] != vpc_id:
            sys.stderr.write(f"{subnet_id} does not match fixture cidr/vpc\n")
            raise SystemExit(1)
        print(f"subnet {subnet_id} {cidr} exists")
        return
    if not missing(found):
        sys.stderr.write(found.stderr)
        raise SystemExit(found.returncode or 1)
    created = aws(
        "ec2",
        "create-subnet",
        "--cli-input-json",
        json.dumps(
            {
                "VpcId": vpc_id,
                "CidrBlock": cidr,
                "AvailabilityZone": az,
                "TagSpecifications": tag_spec("subnet", subnet_id, name),
            }
        ),
        "--query",
        "Subnet.SubnetId",
        "--output",
        "text",
    )
    got_id = created.stdout.strip()
    if got_id != subnet_id:
        sys.stderr.write(
            f"created {got_id} but fixture id is {subnet_id}\n"
            "LocalEmu is missing localemu-patches/init/start.d/20-mirror-resource-ids.py\n"
        )
        raise SystemExit(1)
    print(f"subnet {subnet_id} {cidr} created")


def apply_group(group) -> None:
    require_keys(
        group,
        {"id", "vpcId", "name", "description"},
        {"id", "vpcId", "name", "description"},
        "securityGroup",
    )
    group_id = expect_id("sg", group["id"])
    vpc_id = expect_id("vpc", group["vpcId"])
    name = str(group["name"])
    description = str(group["description"])
    if not name or not description:
        sys.stderr.write("security group name and description are required\n")
        raise SystemExit(1)
    found = aws(
        "ec2",
        "describe-security-groups",
        "--group-ids",
        group_id,
        "--output",
        "json",
        check=False,
    )
    if found.returncode == 0:
        body = json.loads(found.stdout)
        row = body["SecurityGroups"][0]
        if row["VpcId"] != vpc_id or row["GroupName"] != name:
            sys.stderr.write(f"{group_id} does not match fixture vpc/name\n")
            raise SystemExit(1)
        print(f"sg {group_id} {name} exists")
        return
    if not missing(found):
        sys.stderr.write(found.stderr)
        raise SystemExit(found.returncode or 1)
    created = aws(
        "ec2",
        "create-security-group",
        "--cli-input-json",
        json.dumps(
            {
                "GroupName": name,
                "Description": description,
                "VpcId": vpc_id,
                "TagSpecifications": tag_spec("security-group", group_id, None),
            }
        ),
        "--query",
        "GroupId",
        "--output",
        "text",
    )
    got_id = created.stdout.strip()
    if got_id != group_id:
        sys.stderr.write(
            f"created {got_id} but fixture id is {group_id}\n"
            "LocalEmu is missing localemu-patches/init/start.d/20-mirror-resource-ids.py\n"
        )
        raise SystemExit(1)
    print(f"sg {group_id} {name} created")


for vpc in vpcs:
    apply_vpc(vpc)
for subnet in subnets:
    apply_subnet(subnet)
for group in groups:
    apply_group(group)
PY
}

main() {
	local cmd="${1:-}"
	if [[ -z "$cmd" ]]; then
		usage >&2
		exit 2
	fi
	shift
	case "$cmd" in
		mirror) cmd_mirror "$@" ;;
		apply) cmd_apply "$@" ;;
		-h | --help | help) usage ;;
		*)
			echo "unknown command: $cmd" >&2
			usage >&2
			exit 2
			;;
	esac
}

main "$@"
