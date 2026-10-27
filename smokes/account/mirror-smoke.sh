#!/usr/bin/env bash
# Synthetic account-mirror smoke. No real AWS.
# Sad: in-repo fixture write refused; non-local apply refused; dry-run makes no aws calls.
# Happy: apply testdata/mirror/synthetic-vpc.json on a throwaway LocalEmu; describe matches ids and CIDRs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/testdata/mirror/synthetic-vpc.json"
IMAGE_DIGEST_FILE="${AWSBOX_LOCALEMU_DIGEST_FILE:-$ROOT/localemu-patches/IMAGE_DIGEST}"
CID=""
FAKE_DIR=""

cleanup() {
	if [[ -n "$CID" ]]; then
		docker rm -f "$CID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$FAKE_DIR" ]]; then
		rm -rf "$FAKE_DIR"
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
[[ -f "$FIXTURE" ]] || fail "missing $FIXTURE"

FAKE_DIR="$(mktemp -d)"
INVOCATIONS="$FAKE_DIR/invocations"
: >"$INVOCATIONS"
cat >"$FAKE_DIR/aws" <<EOF
#!/bin/sh
echo "\$*" >> "$INVOCATIONS"
exit 99
EOF
chmod +x "$FAKE_DIR/aws"

echo "sad: dry-run lists reads and does not call aws"
DRY="$(PATH="$FAKE_DIR:$PATH" "$ROOT/bin/awsl" mirror dry-run)"
printf '%s\n' "$DRY" | grep -q 'ec2:DescribeVpcs' || fail "dry-run missing DescribeVpcs"
printf '%s\n' "$DRY" | grep -q 'secretsmanager:ListSecrets' || fail "dry-run missing ListSecrets"
python3 - "$DRY" <<'PY'
import sys
text = sys.argv[1]
read, _, excluded = text.partition("## excluded")
if "GetSecretValue" in read.split("## read-only", 1)[-1]:
    sys.stderr.write("GetSecretValue listed as a read\n")
    raise SystemExit(1)
if "secretsmanager:GetSecretValue" not in excluded:
    sys.stderr.write("GetSecretValue missing from excluded\n")
    raise SystemExit(1)
if "ssm:GetParameter" not in excluded:
    sys.stderr.write("GetParameter missing from excluded\n")
    raise SystemExit(1)
PY
[[ ! -s "$INVOCATIONS" ]] || fail "dry-run invoked aws"

echo "sad: refuse fixture path inside the repo"
set +e
PATH="$FAKE_DIR:$PATH" "$ROOT/bin/awsl" mirror --out "$ROOT/testdata/mirror/not-allowed.json" >"$FAKE_DIR/repo.out" 2>"$FAKE_DIR/repo.err"
repo_rc=$?
set -e
[[ "$repo_rc" -eq 1 ]] || fail "in-repo --out exit $repo_rc"
grep -q 'refusing to write' "$FAKE_DIR/repo.err" || fail "in-repo message missing"
[[ ! -e "$ROOT/testdata/mirror/not-allowed.json" ]] || fail "in-repo path was created"
[[ ! -s "$INVOCATIONS" ]] || fail "in-repo --out invoked aws"

echo "sad: gitignored --out is not written (read path later)"
set +e
PATH="$FAKE_DIR:$PATH" "$ROOT/bin/awsl" mirror --out "$ROOT/.awsbox/mirror-out" >"$FAKE_DIR/ign.out" 2>"$FAKE_DIR/ign.err"
ign_rc=$?
set -e
[[ "$ign_rc" -eq 2 ]] || fail "gitignored --out exit $ign_rc"
grep -q 'nothing was written' "$FAKE_DIR/ign.err" || fail "gitignored message missing"
[[ ! -e "$ROOT/.awsbox/mirror-out" ]] || fail "gitignored out path was created"
[[ ! -s "$INVOCATIONS" ]] || fail "gitignored --out invoked aws"

echo "sad: apply refuses a non-local endpoint"
set +e
AWSBOX_IAM_ENDPOINT="https://ec2.us-east-1.amazonaws.com" \
	PATH="$FAKE_DIR:$PATH" \
	"$ROOT/bin/awsl" apply "$FIXTURE" >"$FAKE_DIR/ep.out" 2>"$FAKE_DIR/ep.err"
ep_rc=$?
set -e
[[ "$ep_rc" -eq 1 ]] || fail "non-local apply exit $ep_rc"
grep -q 'endpoint is not local' "$FAKE_DIR/ep.err" || fail "non-local message missing"
[[ ! -s "$INVOCATIONS" ]] || fail "non-local apply invoked aws"

echo "happy: ephemeral LocalEmu + apply + describe"
digest="$(grep -E '^sha256:[0-9a-f]{64}$' "$IMAGE_DIGEST_FILE" | tail -n 1)"
[[ -n "$digest" ]] || fail "bad image digest file"
IMAGE="localemu/localemu@${digest}"
CID="$(
	docker run -d --name "awsl-mirror-smoke-$$" \
		-p 127.0.0.1::4566 \
		-e SERVICES=ec2 \
		-e GATEWAY_LISTEN=0.0.0.0:4566 \
		-e AWS_DEFAULT_REGION=us-east-1 \
		-e PERSISTENCE=0 \
		-e DEBUG=0 \
		-e IAM_ENFORCEMENT=0 \
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

for vpc in doc["resources"]["vpcs"]:
    row = aws("ec2", "describe-vpcs", "--vpc-ids", vpc["id"])["Vpcs"][0]
    assert row["VpcId"] == vpc["id"], row
    assert row["CidrBlock"] == vpc["cidr"], row
    print(f"describe vpc {row['VpcId']} {row['CidrBlock']}")

for subnet in doc["resources"]["subnets"]:
    row = aws("ec2", "describe-subnets", "--subnet-ids", subnet["id"])["Subnets"][0]
    assert row["SubnetId"] == subnet["id"], row
    assert row["CidrBlock"] == subnet["cidr"], row
    assert row["VpcId"] == subnet["vpcId"], row
    print(f"describe subnet {row['SubnetId']} {row['CidrBlock']}")

for group in doc["resources"]["securityGroups"]:
    row = aws("ec2", "describe-security-groups", "--group-ids", group["id"])["SecurityGroups"][0]
    assert row["GroupId"] == group["id"], row
    assert row["VpcId"] == group["vpcId"], row
    assert row["GroupName"] == group["name"], row
    print(f"describe sg {row['GroupId']} {row['GroupName']}")
PY

echo "OK mirror-smoke"
