#!/usr/bin/env bash
# Console labels from a file outside the repo (docs/labels.md).
# Happy: VPC ID + NLB ARN glob show on list and detail.
# Sad: missing file → GET /_awsl/labels is empty and the console shows no label.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
NAME="awsbox-lab-${TS}"
KEEP="${AWSBOX_LABELS_KEEP:-0}"
VPC=""
SUBNET=""
NLB_ARN=""
VITE_PID=""
PORT=""
LABELS=""
LOG=""

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_SMOKE_VPC_LABEL="labels-smoke-vpc"
export AWSBOX_SMOKE_NLB_LABEL="labels-smoke-nlb"
export AWSBOX_SMOKE_VPC_NOTE="labels smoke vpc note"
export AWSBOX_SMOKE_NLB_NOTE="labels smoke nlb note"
export AWSBOX_SMOKE_VPC_LINK="https://example.test/awsbox-vpc"
export AWSBOX_SMOKE_NLB_LINK="https://example.test/awsbox-nlb"
export AWSBOX_SMOKE_NLB_NAME="$NAME"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	local status=$?
	if [[ -n "$VITE_PID" ]]; then
		kill -- "-$VITE_PID" 2>/dev/null || kill "$VITE_PID" 2>/dev/null || true
	fi
	[[ -n "$LABELS" ]] && rm -f "$LABELS"
	[[ -n "$LOG" ]] && rm -f "$LOG"
	if [[ "$KEEP" == "1" ]]; then
		echo "kept VPC=${VPC:-} NLB=${NLB_ARN:-}"
		exit "$status"
	fi
	if [[ -n "$NLB_ARN" ]]; then
		aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN" >/dev/null 2>&1 || true
	fi
	if [[ -n "$SUBNET" ]]; then
		local _
		for _ in $(seq 1 30); do
			aws ec2 delete-subnet --subnet-id "$SUBNET" >/dev/null 2>&1 && break
			sleep 1
		done
	fi
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	exit "$status"
}
trap cleanup EXIT

if ! aws elbv2 describe-load-balancers >/dev/null 2>&1; then
	echo "FAIL: elbv2 is not enabled on ${EP}." >&2
	echo "elbv2 is in docker-compose.yml SERVICES. Recreate the localstack container, then rerun." >&2
	exit 1
fi

VPC="$(aws ec2 create-vpc --cidr-block 10.215.0.0/16 --query 'Vpc.VpcId' --output text)"
SUBNET="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.215.1.0/24 --query 'Subnet.SubnetId' --output text)"
NLB_ARN="$(aws elbv2 create-load-balancer --name "$NAME" --type network --scheme internal --subnets "$SUBNET" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
echo "VPC=${VPC}"
echo "NLB=${NLB_ARN}"

export AWSBOX_SMOKE_VPC_ID="$VPC"
export AWSBOX_SMOKE_NLB_ARN="$NLB_ARN"
# Moto emits loadbalancer/app/ even when Type=network. * covers app and net.
PATTERN="arn:aws:elasticloadbalancing:*:*:loadbalancer/*/${NAME}/*"
export PATTERN

LABELS="$(mktemp /tmp/awsbox-labels.XXXXXX.yaml)"
export LABELS
export ROOT
python3 - <<'PY'
import os
root = os.path.realpath(os.environ["ROOT"])
path = os.path.realpath(os.environ["LABELS"])
if path == root or path.startswith(root + os.sep):
    raise SystemExit(f"labels file must stay outside the repo: {path}")
print(f"labels file outside repo: {path}")
PY
rm -f "$LABELS"

if [[ ! -d "$ROOT/console/node_modules" ]]; then
	(cd "$ROOT/console" && yarn install)
fi

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
LOG="$(mktemp /tmp/awsbox-labels-vite.XXXXXX.log)"
export AWSBOX_LABELS="$LABELS"
export AWSBOX_CONSOLE_URL="http://127.0.0.1:${PORT}"

setsid bash -c "cd \"$ROOT/console\" && exec yarn dev --host 127.0.0.1 --port \"$PORT\"" >"$LOG" 2>&1 &
VITE_PID=$!

ready=0
for _ in $(seq 1 90); do
	if curl -sf --max-time 1 "${AWSBOX_CONSOLE_URL}/_awsl/labels" >/dev/null; then
		ready=1
		break
	fi
	sleep 1
done
if [[ "$ready" != 1 ]]; then
	echo "FAIL: console did not serve /_awsl/labels" >&2
	tail -n 40 "$LOG" >&2 || true
	exit 1
fi

empty="$(curl -sf "${AWSBOX_CONSOLE_URL}/_awsl/labels")"
[[ "$empty" == '{"entries":[]}' ]] || {
	echo "FAIL: missing labels file returned: ${empty}" >&2
	exit 1
}

python3 - <<'PY'
import os
from pathlib import Path
text = f"""{os.environ['AWSBOX_SMOKE_VPC_ID']}:
  label: {os.environ['AWSBOX_SMOKE_VPC_LABEL']}
  note: {os.environ['AWSBOX_SMOKE_VPC_NOTE']}
  link: "{os.environ['AWSBOX_SMOKE_VPC_LINK']}"
"{os.environ['PATTERN']}":
  label: {os.environ['AWSBOX_SMOKE_NLB_LABEL']}
  note: {os.environ['AWSBOX_SMOKE_NLB_NOTE']}
  link: "{os.environ['AWSBOX_SMOKE_NLB_LINK']}"
"""
Path(os.environ["LABELS"]).write_text(text)
PY

python3 - <<'PY'
import json, os, re, urllib.request
url = os.environ["AWSBOX_CONSOLE_URL"] + "/_awsl/labels"
with urllib.request.urlopen(url) as res:
    body = json.load(res)
entries = {e["match"]: e for e in body["entries"]}
vpc = os.environ["AWSBOX_SMOKE_VPC_ID"]
pattern = os.environ["PATTERN"]
assert vpc in entries, entries
assert entries[vpc]["label"] == os.environ["AWSBOX_SMOKE_VPC_LABEL"]
assert entries[vpc]["note"] == os.environ["AWSBOX_SMOKE_VPC_NOTE"]
assert entries[vpc]["link"] == os.environ["AWSBOX_SMOKE_VPC_LINK"]
assert pattern in entries, entries
assert entries[pattern]["label"] == os.environ["AWSBOX_SMOKE_NLB_LABEL"]
src = "^"
for ch in pattern:
    if ch == "*":
        src += ".*"
    elif ch == "?":
        src += "."
    else:
        src += re.escape(ch)
src += "$"
arn = os.environ["AWSBOX_SMOKE_NLB_ARN"]
if re.fullmatch(src, arn) is None:
    raise SystemExit(f"NLB ARN did not match glob: {arn} vs {pattern}")
print("GET /_awsl/labels ok")
PY

(
	cd "$ROOT/console"
	yarn playwright test e2e/labels.spec.ts -g "shows VPC and NLB labels"
)

printf ':\n' >"$LABELS"
bad="$(curl -s -o /tmp/awsbox-labels-bad.json -w '%{http_code}' "${AWSBOX_CONSOLE_URL}/_awsl/labels")"
[[ "$bad" == "400" ]] || {
	echo "FAIL: invalid labels file status ${bad}" >&2
	cat /tmp/awsbox-labels-bad.json >&2 || true
	exit 1
}
rm -f /tmp/awsbox-labels-bad.json

rm -f "$LABELS"
gone="$(curl -sf "${AWSBOX_CONSOLE_URL}/_awsl/labels")"
[[ "$gone" == '{"entries":[]}' ]] || {
	echo "FAIL: missing labels file returned: ${gone}" >&2
	exit 1
}

(
	cd "$ROOT/console"
	AWSBOX_SMOKE_LABELS_ABSENT=1 yarn playwright test e2e/labels.spec.ts -g "omits labels"
)

echo "labels smoke ok"
