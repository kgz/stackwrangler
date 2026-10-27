#!/usr/bin/env bash
# Tagged mirror fixture smoke (#256). No real AWS.
# Apply testdata/mirror/tagged-vpc.json on a throwaway LocalEmu; describe shows
# Name / aws-cdk:subnet-name / Tier=private tags; Terraform data sources resolve.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/local/bin:${PATH:-}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/testdata/mirror/tagged-vpc.json"
IMAGE_DIGEST_FILE="${AWSBOX_LOCALEMU_DIGEST_FILE:-$ROOT/localemu-patches/IMAGE_DIGEST}"
CID=""
TF_DIR=""

cleanup() {
	if [[ -n "$CID" ]]; then
		docker rm -f "$CID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$TF_DIR" ]]; then
		rm -rf "$TF_DIR"
	fi
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

command -v python3 >/dev/null || fail "python3 is required"
command -v aws >/dev/null || fail "aws cli is required"
command -v docker >/dev/null || fail "docker is required"
command -v terraform >/dev/null || fail "terraform is required"
command -v curl >/dev/null || fail "curl is required"
[[ -f "$FIXTURE" ]] || fail "missing $FIXTURE"

echo "happy: ephemeral LocalEmu + tagged apply + describe + terraform data sources"
digest="$(grep -E '^sha256:[0-9a-f]{64}$' "$IMAGE_DIGEST_FILE" | tail -n 1)"
[[ -n "$digest" ]] || fail "bad image digest file"
IMAGE="localemu/localemu@${digest}"
CID="$(
	docker run -d --name "awsl-mirror-tags-smoke-$$" \
		-p 127.0.0.1::4566 \
		-e SERVICES=ec2,iam,sts \
		-e GATEWAY_LISTEN=0.0.0.0:4566 \
		-e AWS_DEFAULT_REGION=us-east-1 \
		-e PERSISTENCE=0 \
		-e DEBUG=0 \
		-e IAM_ENFORCEMENT=1 \
		-e "ROOT_ACCESS_KEYS=${AWSBOX_ACCESS_KEY:-awsbox}" \
		-v "$ROOT/localemu-patches/init/start.d:/etc/localemu/init/start.d:ro" \
		"$IMAGE"
)"
port="$(docker port "$CID" 4566/tcp | awk -F: 'NR==1 {print $NF}')"
[[ -n "$port" ]] || fail "no published port"
EP="http://127.0.0.1:${port}"
ready=0
for _ in $(seq 1 90); do
	if curl -sf --max-time 2 "${EP}/_localemu/health" >/dev/null 2>&1 \
		|| curl -sf --max-time 2 "${EP}/_localstack/health" >/dev/null 2>&1; then
		ready=1
		break
	fi
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
	if [[ "$code" =~ ^[12345][0-9][0-9]$ ]]; then
		ready=1
		break
	fi
	sleep 1
done
if [[ "$ready" -ne 1 ]]; then
	docker logs "$CID" >&2 || true
	fail "emulator did not become ready on ${EP}"
fi
docker logs "$CID" 2>&1 | grep -q 'mirror resource-id pin enabled' || {
	docker logs "$CID" >&2 || true
	fail "resource-id pin hook did not load"
}

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_ENDPOINT_URL AWS_SESSION_TOKEN || true

AWSBOX_IAM_ENDPOINT="$EP" "$ROOT/bin/awsl" apply "$FIXTURE"
AWSBOX_IAM_ENDPOINT="$EP" "$ROOT/bin/awsl" apply "$FIXTURE"

python3 - "$FIXTURE" "$EP" <<'PY'
import json, os, subprocess, sys

fixture, endpoint = sys.argv[1], sys.argv[2]
doc = json.load(open(fixture, encoding="utf-8"))
region = doc["region"]

def aws(*args):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": os.environ.get("HOME", "/tmp"),
        "AWS_ACCESS_KEY_ID": os.environ["AWS_ACCESS_KEY_ID"],
        "AWS_SECRET_ACCESS_KEY": os.environ["AWS_SECRET_ACCESS_KEY"],
        "AWS_DEFAULT_REGION": region,
        "AWS_EC2_METADATA_DISABLED": "true",
        "AWS_PAGER": "",
    }
    result = subprocess.run(
        ["aws", "--endpoint-url", endpoint, "--region", region, *args, "--output", "json"],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode or 1)
    return json.loads(result.stdout)

def tag_map(row):
    out = {}
    for tag in row.get("Tags") or []:
        out[tag["Key"]] = tag["Value"]
    return out

def expect_tags(have, want, label):
    for key, value in want.items():
        got = have.get(key)
        if got != value:
            raise SystemExit(f"{label}: tag {key}={got!r}, want {value!r}")

for vpc in doc["resources"]["vpcs"]:
    row = aws("ec2", "describe-vpcs", "--vpc-ids", vpc["id"])["Vpcs"][0]
    tags = tag_map(row)
    want = dict(vpc.get("tags") or {})
    if vpc.get("name"):
        want.setdefault("Name", vpc["name"])
    want["awsbox:resource-id"] = vpc["id"]
    expect_tags(tags, want, vpc["id"])
    print(f"describe vpc tags ok {vpc['id']} Name={tags.get('Name')}")

for subnet in doc["resources"]["subnets"]:
    row = aws("ec2", "describe-subnets", "--subnet-ids", subnet["id"])["Subnets"][0]
    tags = tag_map(row)
    want = dict(subnet.get("tags") or {})
    if subnet.get("name"):
        want.setdefault("Name", subnet["name"])
    want["awsbox:resource-id"] = subnet["id"]
    expect_tags(tags, want, subnet["id"])
    print(
        f"describe subnet tags ok {subnet['id']} "
        f"aws-cdk:subnet-name={tags.get('aws-cdk:subnet-name')}"
    )

for table in doc["resources"].get("routeTables") or []:
    row = aws("ec2", "describe-route-tables", "--route-table-ids", table["id"])["RouteTables"][0]
    tags = tag_map(row)
    want = dict(table.get("tags") or {})
    if table.get("name"):
        want.setdefault("Name", table["name"])
    want["awsbox:resource-id"] = table["id"]
    expect_tags(tags, want, table["id"])
    assoc = {a.get("SubnetId") for a in row.get("Associations") or [] if a.get("SubnetId")}
    for subnet_id in table.get("subnetIds") or []:
        if subnet_id not in assoc:
            raise SystemExit(f"{table['id']}: missing assoc {subnet_id}")
    print(f"describe rtb tags ok {table['id']} Tier={tags.get('Tier')}")

for group in doc["resources"]["securityGroups"]:
    row = aws("ec2", "describe-security-groups", "--group-ids", group["id"])["SecurityGroups"][0]
    tags = tag_map(row)
    want = dict(group.get("tags") or {})
    want["awsbox:resource-id"] = group["id"]
    expect_tags(tags, want, group["id"])
    print(f"describe sg tags ok {group['id']}")

# Filter-by-tag describe (same shape Terraform data sources use)
vpcs = aws(
    "ec2",
    "describe-vpcs",
    "--filters",
    "Name=tag:Name,Values=tf-lookup-vpc",
)["Vpcs"]
assert len(vpcs) == 1 and vpcs[0]["VpcId"] == "vpc-02560000000000001", vpcs
subnets = aws(
    "ec2",
    "describe-subnets",
    "--filters",
    "Name=tag:aws-cdk:subnet-name,Values=Private",
)["Subnets"]
assert {s["SubnetId"] for s in subnets} == {
    "subnet-02560000000000001",
    "subnet-02560000000000002",
}, subnets
rtbs = aws(
    "ec2",
    "describe-route-tables",
    "--filters",
    "Name=tag:Tier,Values=private",
)["RouteTables"]
assert len(rtbs) == 1 and rtbs[0]["RouteTableId"] == "rtb-02560000000000001", rtbs
print("describe-*-filters by tag ok")
PY

TF_DIR="$(mktemp -d)"
cat >"$TF_DIR/main.tf" <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "${AWS_ACCESS_KEY_ID}"
  secret_key                  = "${AWS_SECRET_ACCESS_KEY}"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "${EP}"
  }
}

data "aws_vpc" "lookup" {
  filter {
    name   = "tag:Name"
    values = ["tf-lookup-vpc"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "tag:aws-cdk:subnet-name"
    values = ["Private"]
  }
}

data "aws_route_tables" "private" {
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

output "vpc_id" {
  value = data.aws_vpc.lookup.id
}

output "subnet_ids" {
  value = sort(data.aws_subnets.private.ids)
}

output "route_table_ids" {
  value = sort(data.aws_route_tables.private.ids)
}
EOF

(
	cd "$TF_DIR"
	terraform init -input=false -no-color >/dev/null
	terraform apply -input=false -auto-approve -no-color >/dev/null
	vpc_id="$(terraform output -raw vpc_id)"
	subnet_ids="$(terraform output -json subnet_ids)"
	rtb_ids="$(terraform output -json route_table_ids)"
	[[ "$vpc_id" == "vpc-02560000000000001" ]] || fail "terraform vpc_id=$vpc_id"
	python3 - "$subnet_ids" "$rtb_ids" <<'PY'
import json, sys
subnets = json.loads(sys.argv[1])
rtbs = json.loads(sys.argv[2])
assert subnets == [
    "subnet-02560000000000001",
    "subnet-02560000000000002",
], subnets
assert rtbs == ["rtb-02560000000000001"], rtbs
print("terraform data sources ok")
PY
)

echo "OK mirror-tags-smoke"
