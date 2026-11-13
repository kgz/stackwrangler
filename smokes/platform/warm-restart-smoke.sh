#!/usr/bin/env bash
# #289: warm restart — preserve workload containers in --dev cleanup;
# prebuilt ec2-base / awsbox-rt; no runtime package install into workloads;
# live down → up --dev keeps the same EC2/ECS Docker container IDs.
#
# Part A needs only Docker (no LocalEmu). Live parts need a free gate:
#   ./bin/batch-resource-gate.sh check --need-up
# Set AWSBOX_WARM_RESTART_SKIP_LIVE=1 to park live (explicit only).
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
CLUSTER_NAME=""
TASK_ARN=""
DID_LIVE_STACK=0

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

fail() { echo "FAIL: $*" >&2; exit 1; }

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

localemu_cid() {
	local cid
	cid="$(docker ps --format '{{.Names}}' | grep -E '^awsl-wt-289-localstack-1$' | head -1 || true)"
	if [[ -z "$cid" ]]; then
		cid="$(docker ps --filter "label=com.docker.compose.project.working_dir=$ROOT" --format '{{.Names}}' | grep -E 'localstack-1$' | head -1 || true)"
	fi
	printf '%s' "$cid"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "${INSTANCE_ID:-}" ]]; then
		aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
	fi
	if [[ -n "${TASK_ARN:-}" && -n "${CLUSTER_NAME:-}" ]]; then
		aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	if [[ -n "${CLUSTER_NAME:-}" ]]; then
		aws ecs delete-cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1 || true
	fi
	[[ -n "${CTR:-}" ]] && docker rm -f "$CTR" >/dev/null 2>&1 || true
	[[ -n "${NET:-}" ]] && docker network rm "$NET" >/dev/null 2>&1 || true
	if [[ "$DID_LIVE_STACK" -eq 1 ]]; then
		"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
	fi
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
CTR=""
NET=""
echo "OK: --force cleaned workload + orphan network"

echo "==> #289 A: ensure_warm_images makes ec2-base + awsbox-rt from shared Dockerfiles"
[[ -f "$ROOT/docker/Dockerfile.ec2-base" ]] || fail "missing docker/Dockerfile.ec2-base"
[[ -f "$ROOT/docker/Dockerfile.awsbox-rt" ]] || fail "missing docker/Dockerfile.awsbox-rt"
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
	echo "SKIP live (#289): AWSBOX_WARM_RESTART_SKIP_LIVE=1 (explicit park)"
	echo "OK: warm-restart-smoke (offline parts)"
	exit 0
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
endpoint_up=0
if [[ "$code" =~ ^[12345][0-9][0-9]$ ]]; then
	endpoint_up=1
fi

cid="$(localemu_cid)"
if [[ -n "$cid" ]]; then
	# Stack is up for this worktree — required #289 path must be applied.
	if ! docker exec "$cid" python3 - <<'PY'
import localemu.services.ec2.docker.sg_iptables as sg

fn = sg.ensure_iptables_in_container
assert getattr(fn, "_awsbox_probe_only", False), "ensure_iptables not probe-only (#289)"
print("OK: ensure_iptables probe-only flag")
PY
	then
		fail "LocalEmu $cid running without #289 probe-only hook (recreate stack with this worktree)"
	fi
	docker exec "$cid" sh -c 'test -f /opt/awsbox/docker/Dockerfile.ec2-base && test -f /opt/awsbox/docker/Dockerfile.awsbox-rt' \
		|| fail "LocalEmu $cid missing /opt/awsbox/docker warm Dockerfiles (#289)"
	docker image inspect localemu/ec2-base:v4 >/dev/null 2>&1 \
		|| fail "localemu/ec2-base:v4 missing while LocalEmu is up (#289)"
	docker image inspect localemu/awsbox-rt:latest >/dev/null 2>&1 \
		|| fail "localemu/awsbox-rt missing while LocalEmu is up (#289)"
elif [[ "$endpoint_up" -eq 1 ]]; then
	fail "LocalEmu reachable at $EP but no container for this worktree — cannot verify #289 probe-only path"
else
	echo "NOTE: LocalEmu not up yet; live e2e will bring up --dev"
fi

echo "==> #289 B/C: down → up --dev keeps same EC2/ECS container IDs"
DID_LIVE_STACK=1
# Leave any foreign/test stack cleanly; warm-ID proof needs --dev preserve.
"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
"$ROOT/bin/stackwrangler" up --dev

cid="$(localemu_cid)"
[[ -n "$cid" ]] || fail "no LocalEmu after up --dev"
if ! docker exec "$cid" python3 - <<'PY'
import localemu.services.ec2.docker.sg_iptables as sg

fn = sg.ensure_iptables_in_container
assert getattr(fn, "_awsbox_probe_only", False), "ensure_iptables not probe-only after up --dev (#289)"
print("OK: probe-only after up --dev")
PY
then
	fail "up --dev did not apply #289 probe-only hook"
fi

ami="$(aws ec2 describe-images --query 'Images[0].ImageId' --output text 2>/dev/null || true)"
[[ -n "$ami" && "$ami" != "None" ]] || fail "describe-images unavailable after up --dev"

run_json="$(aws ec2 run-instances --image-id "$ami" --instance-type t2.micro --count 1 --output json)" \
	|| fail "RunInstances failed"
INSTANCE_ID="$(echo "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])')"
[[ -n "$INSTANCE_ID" ]] || fail "no instance id"

ec2_name="localemu-ec2-${INSTANCE_ID}"
found=""
for _ in $(seq 1 90); do
	if docker inspect "$ec2_name" >/dev/null 2>&1; then
		found=1
		break
	fi
	sleep 1
done
[[ -n "$found" ]] || fail "No such container: $ec2_name (EC2 base/reuse path)"
EC2_ID="$(docker inspect -f '{{.Id}}' "$ec2_name")"
[[ -n "$EC2_ID" ]] || fail "empty EC2 docker id"
echo "OK: EC2 container $ec2_name id=${EC2_ID:0:12}"

CLUSTER_NAME="sw289-warm-${TS}"
FAMILY="sw289-warm-${TS}"
aws ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null
aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--container-definitions '[{"name":"sleep","image":"alpine:3.20","essential":true,"command":["sleep","3600"],"memory":128}]' \
	>/dev/null
TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER_NAME" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask returned no taskArn"

ecs_name=""
ecs_id=""
for _ in $(seq 1 90); do
	ecs_name="$(docker ps -a --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1 || true)"
	if [[ -n "$ecs_name" ]]; then
		ecs_id="$(docker inspect -f '{{.Id}}' "$ecs_name")"
		break
	fi
	sleep 1
done
[[ -n "$ecs_id" && -n "$ecs_name" ]] || fail "No docker container for task $TASK_ARN"
echo "OK: ECS container $ecs_name id=${ecs_id:0:12}"

echo "==> down (preserve --dev workloads)"
"$ROOT/bin/stackwrangler" down
docker inspect "$EC2_ID" >/dev/null 2>&1 || fail "down removed EC2 container id $EC2_ID"
docker inspect "$ecs_id" >/dev/null 2>&1 || fail "down removed ECS container id $ecs_id"
echo "OK: containers survived down"

echo "==> up --dev again"
"$ROOT/bin/stackwrangler" up --dev

docker inspect "$EC2_ID" >/dev/null 2>&1 || fail "EC2 container id changed/missing after up --dev (was $EC2_ID)"
docker inspect "$ecs_id" >/dev/null 2>&1 || fail "ECS container id changed/missing after up --dev (was $ecs_id)"
ec2_state="$(docker inspect -f '{{.State.Status}}' "$EC2_ID")"
ecs_state="$(docker inspect -f '{{.State.Status}}' "$ecs_id")"
# Reconcile may take a moment to docker start.
for _ in $(seq 1 60); do
	ec2_state="$(docker inspect -f '{{.State.Status}}' "$EC2_ID")"
	ecs_state="$(docker inspect -f '{{.State.Status}}' "$ecs_id")"
	if [[ "$ec2_state" == "running" && "$ecs_state" == "running" ]]; then
		break
	fi
	sleep 1
done
[[ "$ec2_state" == "running" ]] || fail "EC2 container not running after warm up (state=$ec2_state)"
[[ "$ecs_state" == "running" ]] || fail "ECS container not running after warm up (state=$ecs_state)"
echo "OK: same EC2/ECS container IDs running after down → up --dev"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
INSTANCE_ID=""
if [[ -n "$TASK_ARN" ]]; then
	aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TASK_ARN" >/dev/null 2>&1 || true
	TASK_ARN=""
fi

echo "OK: warm-restart-smoke (#289)"
