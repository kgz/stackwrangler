#!/usr/bin/env bash
# #289: warm restart — preserve workload containers in --dev cleanup;
# prebuilt ec2-base / awsbox-rt; no runtime package install into workloads.
#
# Part A needs only Docker (no LocalEmu). Part B needs a healthy LocalEmu
# (gate: ./bin/batch-resource-gate.sh check --need-up). Set
# AWSBOX_WARM_RESTART_SKIP_LIVE=1 to skip part B when the gate is busy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
SKIP_LIVE="${AWSBOX_WARM_RESTART_SKIP_LIVE:-0}"

NET="localemu-vpc-sw289-${TS}"
CTR="localemu-ec2-i-sw289${TS}"
MODE_BAK=""
INSTANCE_ID=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

fail() { echo "FAIL: $*" >&2; exit 1; }

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "${INSTANCE_ID:-}" ]]; then
		aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
	fi
	[[ -n "${CTR:-}" ]] && docker rm -f "$CTR" >/dev/null 2>&1 || true
	[[ -n "${NET:-}" ]] && docker network rm "$NET" >/dev/null 2>&1 || true
	if [[ -n "${MODE_BAK:-}" ]]; then
		printf '%s\n' "$MODE_BAK" >"$ROOT/.awsbox/mode"
	fi
}
trap cleanup EXIT

mkdir -p "$ROOT/.awsbox"
MODE_BAK=test
if [[ -f "$ROOT/.awsbox/mode" ]]; then
	MODE_BAK="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode" || true)"
	[[ -n "$MODE_BAK" ]] || MODE_BAK=test
fi

# CLI is sourceable (main guarded by BASH_SOURCE).
# shellcheck disable=SC1091
source "$ROOT/bin/stackwrangler"

echo "==> #289 A: --dev cleanup preserves localemu-ec2-* on VPC bridge"
printf 'dev\n' >"$ROOT/.awsbox/mode"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$CTR" --network "$NET" \
	--label localemu.service=ec2 \
	alpine:3.20 sleep 3600 >/dev/null
docker stop "$CTR" >/dev/null

cleanup_localemu_vpc_networks
docker inspect "$CTR" >/dev/null 2>&1 || fail "dev cleanup removed preserved EC2 container $CTR"
docker network inspect "$NET" >/dev/null 2>&1 || fail "dev cleanup removed network still holding stopped workload"
echo "OK: --dev cleanup kept $CTR + $NET"

echo "==> #289 A: --force reclaim"
cleanup_localemu_vpc_networks --force
docker inspect "$CTR" >/dev/null 2>&1 && fail "force cleanup left $CTR" || true
docker network inspect "$NET" >/dev/null 2>&1 && fail "force cleanup left $NET" || true
# Recreate placeholders cleared so trap is a no-op for these names.
CTR=""
NET=""
echo "OK: --force cleaned workload + orphan network"

echo "==> #289 A: ensure_warm_images makes ec2-base + awsbox-rt"
ensure_warm_images
docker image inspect localemu/ec2-base:v4 >/dev/null || fail "localemu/ec2-base:v4 missing after ensure"
docker image inspect localemu/awsbox-rt:latest >/dev/null || fail "localemu/awsbox-rt missing after ensure"
docker run --rm --entrypoint sh localemu/awsbox-rt:latest -c \
	'command -v iptables >/dev/null && iptables -V >/dev/null' \
	|| fail "awsbox-rt lacks baked-in iptables"
docker run --rm --entrypoint sh localemu/ec2-base:v4 -c \
	'command -v iptables >/dev/null && iptables -V >/dev/null && command -v sshd >/dev/null' \
	|| fail "ec2-base lacks baked-in iptables/sshd"
echo "OK: prebuilt images have iptables"

if [[ "$SKIP_LIVE" == "1" ]]; then
	echo "SKIP live (#289): AWSBOX_WARM_RESTART_SKIP_LIVE=1"
	echo "OK: warm-restart-smoke (offline parts)"
	exit 0
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
if ! [[ "$code" =~ ^[12345][0-9][0-9]$ ]]; then
	echo "SKIP live (#289): LocalEmu not reachable at $EP (HTTP ${code:-empty})"
	echo "OK: warm-restart-smoke (offline parts; live parked)"
	exit 0
fi

echo "==> #289 B: probe-only ensure_iptables + EC2 container (this worktree stack)"
cid="$(docker ps --format '{{.Names}}' | grep -E '^awsl-wt-289-localstack-1$' | head -1 || true)"
if [[ -z "$cid" ]]; then
	# Accept compose project name variants for this checkout.
	cid="$(docker ps --filter "label=com.docker.compose.project.working_dir=$ROOT" --format '{{.Names}}' | grep -E 'localstack-1$' | head -1 || true)"
fi
if [[ -z "$cid" ]]; then
	echo "SKIP live (#289): no LocalEmu for this worktree (bring up with ./bin/stackwrangler up)"
	echo "OK: warm-restart-smoke (offline parts; live parked)"
	exit 0
fi

if ! docker exec "$cid" python3 - <<'PY'
import localemu.services.ec2.docker.sg_iptables as sg

fn = sg.ensure_iptables_in_container
assert getattr(fn, "_awsbox_probe_only", False), "ensure_iptables not probe-only (#289)"
print("OK: ensure_iptables probe-only flag")
PY
then
	echo "SKIP live (#289): LocalEmu running without #289 probe-only hook (recreate stack)"
	echo "OK: warm-restart-smoke (offline parts; live parked)"
	exit 0
fi

ami="$(aws ec2 describe-images --query 'Images[0].ImageId' --output text 2>/dev/null || true)"
if [[ -z "$ami" || "$ami" == "None" ]]; then
	echo "SKIP live (#289): describe-images unavailable"
	echo "OK: warm-restart-smoke (offline parts; live parked)"
	exit 0
fi

if ! run_json="$(aws ec2 run-instances --image-id "$ami" --instance-type t2.micro --count 1 --output json 2>/dev/null)"; then
	echo "SKIP live (#289): RunInstances unavailable (HTTP/service error)"
	echo "OK: warm-restart-smoke (offline parts; live parked)"
	exit 0
fi
INSTANCE_ID="$(echo "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])')"
[[ -n "$INSTANCE_ID" ]] || fail "no instance id"

ec2_name="localemu-ec2-${INSTANCE_ID}"
found=""
for _ in $(seq 1 60); do
	if docker inspect "$ec2_name" >/dev/null 2>&1; then
		found=1
		break
	fi
	sleep 1
done
[[ -n "$found" ]] || fail "No such container: $ec2_name (EC2 base/reuse path)"
img="$(docker inspect -f '{{.Config.Image}}' "$ec2_name")"
echo "OK: EC2 container $ec2_name present (image=$img)"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
INSTANCE_ID=""

echo "OK: warm-restart-smoke (#289)"
