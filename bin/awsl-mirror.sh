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

apply creates VPC, subnet, route table, and security group resources from a
synthetic fixture on AWSBOX_IAM_ENDPOINT (default http://127.0.0.1:4566). The
endpoint must be loopback. Ids are pinned with the tag awsbox:resource-id,
which LocalEmu honors after
localemu-patches/init/start.d/20-mirror-resource-ids.py is loaded (recreate
the emulator). Fixture tags (plus optional name → Name) are applied so
tag-filtered Terraform data sources resolve.

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
    "rtb": re.compile(r"^rtb-[0-9a-f]{8,17}$"),
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


def reject_secrets(node, *, under_tags: bool = False) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            # Tag keys like Environment are allowed; secret-shaped fields are not.
            if not under_tags and str(key).lower() in FORBIDDEN_KEYS:
                sys.stderr.write(f"refusing fixture field {key}\n")
                raise SystemExit(1)
            reject_secrets(value, under_tags=under_tags or key == "tags")
        return
    if isinstance(node, list):
        for item in node:
            reject_secrets(item, under_tags=under_tags)


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
    {"vpcs", "subnets", "securityGroups", "routeTables"},
    {"vpcs", "subnets", "securityGroups"},
    "resources",
)

vpcs = resources["vpcs"]
subnets = resources["subnets"]
groups = resources["securityGroups"]
route_tables = resources.get("routeTables", [])
if not isinstance(vpcs, list) or not isinstance(subnets, list) or not isinstance(groups, list):
    sys.stderr.write("resources arrays must be lists\n")
    raise SystemExit(1)
if not isinstance(route_tables, list):
    sys.stderr.write("resources.routeTables must be a list\n")
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


def missing(result) -> bool:
    blob = (result.stderr or "") + (result.stdout or "")
    return result.returncode != 0 and "NotFound" in blob


def expect_id(kind: str, value: str) -> str:
    if not ID_RE[kind].match(value):
        sys.stderr.write(f"invalid {kind} id: {value}\n")
        raise SystemExit(1)
    return value


def parse_tags(raw, label: str) -> dict:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        sys.stderr.write(f"{label} tags must be an object of string values\n")
        raise SystemExit(1)
    out = {}
    for key, value in raw.items():
        if not isinstance(key, str) or not isinstance(value, str):
            sys.stderr.write(f"{label} tags keys and values must be strings\n")
            raise SystemExit(1)
        if key == TAG and value:
            sys.stderr.write(
                f"{label}: do not set {TAG} in tags; it is taken from id\n"
            )
            raise SystemExit(1)
        out[key] = value
    return out


def desired_tags(resource_id: str, name, raw_tags, label: str) -> list:
    merged = parse_tags(raw_tags, label)
    if name:
        merged.setdefault("Name", str(name))
    merged[TAG] = resource_id
    return [{"Key": key, "Value": value} for key, value in merged.items()]


def tag_spec(resource_type: str, tags: list) -> list:
    return [{"ResourceType": resource_type, "Tags": tags}]


def ensure_tags(resource_id: str, tags: list) -> None:
    wanted = {tag["Key"]: tag["Value"] for tag in tags}
    listed = aws(
        "ec2",
        "describe-tags",
        "--filters",
        f"Name=resource-id,Values={resource_id}",
        "--output",
        "json",
        check=False,
    )
    have = {}
    if listed.returncode == 0:
        for row in json.loads(listed.stdout).get("Tags") or []:
            key = row.get("Key")
            value = row.get("Value")
            if isinstance(key, str) and isinstance(value, str):
                have[key] = value
    missing_or_diff = [
        {"Key": key, "Value": value}
        for key, value in wanted.items()
        if have.get(key) != value
    ]
    if not missing_or_diff:
        return
    aws(
        "ec2",
        "create-tags",
        "--resources",
        resource_id,
        "--tags",
        *[f"Key={tag['Key']},Value={tag['Value']}" for tag in missing_or_diff],
    )


def apply_vpc(vpc) -> None:
    require_keys(vpc, {"id", "cidr", "name", "tags"}, {"id", "cidr"}, "vpc")
    vpc_id = expect_id("vpc", vpc["id"])
    cidr = cidr_ok(vpc["cidr"])
    tags = desired_tags(vpc_id, vpc.get("name"), vpc.get("tags"), "vpc")
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
        ensure_tags(vpc_id, tags)
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
                "TagSpecifications": tag_spec("vpc", tags),
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
        {"id", "vpcId", "cidr", "availabilityZone", "name", "tags"},
        {"id", "vpcId", "cidr", "availabilityZone"},
        "subnet",
    )
    subnet_id = expect_id("subnet", subnet["id"])
    vpc_id = expect_id("vpc", subnet["vpcId"])
    cidr = cidr_ok(subnet["cidr"])
    az = str(subnet["availabilityZone"])
    tags = desired_tags(subnet_id, subnet.get("name"), subnet.get("tags"), "subnet")
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
        ensure_tags(subnet_id, tags)
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
                "TagSpecifications": tag_spec("subnet", tags),
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


def ensure_subnet_assoc(rtb_id: str, subnet_id: str) -> None:
    listed = aws(
        "ec2",
        "describe-route-tables",
        "--route-table-ids",
        rtb_id,
        "--output",
        "json",
    )
    row = json.loads(listed.stdout)["RouteTables"][0]
    for assoc in row.get("Associations") or []:
        if assoc.get("SubnetId") == subnet_id:
            return
    aws(
        "ec2",
        "associate-route-table",
        "--route-table-id",
        rtb_id,
        "--subnet-id",
        subnet_id,
    )


def apply_route_table(table) -> None:
    require_keys(
        table,
        {"id", "vpcId", "name", "tags", "subnetIds"},
        {"id", "vpcId"},
        "routeTable",
    )
    rtb_id = expect_id("rtb", table["id"])
    vpc_id = expect_id("vpc", table["vpcId"])
    tags = desired_tags(rtb_id, table.get("name"), table.get("tags"), "routeTable")
    subnet_ids = table.get("subnetIds") or []
    if not isinstance(subnet_ids, list):
        sys.stderr.write("routeTable.subnetIds must be a list\n")
        raise SystemExit(1)
    for subnet_id in subnet_ids:
        expect_id("subnet", subnet_id)
    found = aws(
        "ec2",
        "describe-route-tables",
        "--route-table-ids",
        rtb_id,
        "--output",
        "json",
        check=False,
    )
    if found.returncode == 0:
        body = json.loads(found.stdout)
        row = body["RouteTables"][0]
        if row["VpcId"] != vpc_id:
            sys.stderr.write(f"{rtb_id} does not match fixture vpc\n")
            raise SystemExit(1)
        ensure_tags(rtb_id, tags)
        for subnet_id in subnet_ids:
            ensure_subnet_assoc(rtb_id, subnet_id)
        print(f"rtb {rtb_id} exists")
        return
    if not missing(found):
        sys.stderr.write(found.stderr)
        raise SystemExit(found.returncode or 1)
    created = aws(
        "ec2",
        "create-route-table",
        "--cli-input-json",
        json.dumps(
            {
                "VpcId": vpc_id,
                "TagSpecifications": tag_spec("route-table", tags),
            }
        ),
        "--query",
        "RouteTable.RouteTableId",
        "--output",
        "text",
    )
    got_id = created.stdout.strip()
    if got_id != rtb_id:
        sys.stderr.write(
            f"created {got_id} but fixture id is {rtb_id}\n"
            "LocalEmu is missing localemu-patches/init/start.d/20-mirror-resource-ids.py\n"
        )
        raise SystemExit(1)
    for subnet_id in subnet_ids:
        ensure_subnet_assoc(rtb_id, subnet_id)
    print(f"rtb {rtb_id} created")


def apply_group(group) -> None:
    require_keys(
        group,
        {"id", "vpcId", "name", "description", "tags"},
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
    tags = desired_tags(group_id, None, group.get("tags"), "securityGroup")
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
        ensure_tags(group_id, tags)
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
                "TagSpecifications": tag_spec("security-group", tags),
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
for table in route_tables:
    apply_route_table(table)
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
