#!/usr/bin/env bash
# Apply examples/terraform/ec2-hello and prove user-data ran inside the container.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/terraform/ec2-hello"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
PREFIX="awsbox-ec2-$(date +%s)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

mkdir -p "$EX/build"
cd "$EX"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="name_prefix=${PREFIX}"

IID="$(terraform output -raw instance_id)"
PIP="$(terraform output -raw private_ip)"
echo "INSTANCE=${IID} PRIVATE_IP=${PIP}"

STATE=""
for _ in $(seq 1 90); do
	STATE="$(
		aws --endpoint-url "$EP" ec2 describe-instances --instance-ids "$IID" \
			--query 'Reservations[0].Instances[0].State.Name' --output text
	)"
	echo "state=${STATE}"
	[[ "$STATE" == "running" ]] && break
	[[ "$STATE" == "terminated" || "$STATE" == "shutting-down" ]] && {
		echo "FAIL: instance ${STATE}" >&2
		exit 1
	}
	sleep 2
done
[[ "$STATE" == "running" ]] || {
	echo "FAIL: not running" >&2
	exit 1
}

# Find Docker container for this instance and read user-data output
CID=""
HELLO=""
for _ in $(seq 1 60); do
	CID="$(
		docker ps --format '{{.ID}} {{.Names}} {{.Labels}}' 2>/dev/null \
			| grep -E "${IID}|localemu.*ec2|ec2.*${IID}" \
			| awk '{print $1}' | head -1 || true
	)"
	if [[ -z "$CID" ]]; then
		# fallback: newest localemu ec2-ish container
		CID="$(
			docker ps --filter "label=localemu.service=ec2" --format '{{.ID}}' | head -1 || true
		)"
	fi
	if [[ -z "$CID" ]]; then
		CID="$(
			docker ps --format '{{.ID}} {{.Image}}' | grep -E 'localemu/ec2|ec2-base' | awk '{print $1}' | head -1 || true
		)"
	fi
	if [[ -n "$CID" ]]; then
		HELLO="$(docker exec "$CID" cat /tmp/hello.txt 2>/dev/null || true)"
		if [[ -n "$HELLO" ]]; then
			break
		fi
	fi
	sleep 2
done

echo "container=${CID:-none}"
echo "hello=${HELLO:-}"

echo "$HELLO" | grep -qi 'Hello from awsbox EC2' || {
	echo "FAIL: /tmp/hello.txt missing or wrong (user-data / container)" >&2
	docker ps --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}' >&2 || true
	exit 1
}

echo "OK: ec2 ${IID} user-data (container ${CID})"

aws --endpoint-url "$EP" ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true
