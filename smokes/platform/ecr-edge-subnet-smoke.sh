#!/usr/bin/env bash
# #750: ECR edge network defaults outside Docker's pools, derives its IP from the subnet,
# and up fails early (naming the network) when another Docker network overlaps.
# Offline: stub `docker` on PATH, no LocalEmu.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Stub docker: `network ls -q` → ids; `network inspect -f …` → "<name> <subnet>" per id.
cat >"$tmp/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"network ls") printf '%s\n' n1 n2 n3 ;;
"network inspect")
	for id in "${@:5}"; do
		case "$id" in
		n1) echo "bridge 172.17.0.0/16" ;;
		n2) echo "leftover-vpc ${STUB_LEFTOVER:-172.31.0.0/16}" ;;
		n3) echo "proj_ecr-host 10.254.218.0/24" ;;
		esac
	done
	;;
esac
EOF
chmod +x "$tmp/docker"

run() { # env assignments… -- shell snippet
	env -i PATH="$tmp:$PATH" HOME="$tmp" "$@" bash -c '
		set -euo pipefail
		STACKWRANGLER_ENV_DEFER=1 source "$0/bin/stackwrangler-env.sh"
		eval "$SNIPPET"
	' "$ROOT" 2>&1
}

out="$(run SNIPPET='sw_ecr_edge_env; echo "$STACKWRANGLER_ECR_HOSTNAME_SUBNET $STACKWRANGLER_ECR_HOSTNAME_IP"')"
[[ "$out" == "10.254.218.0/24 10.254.218.10" ]] || fail "default subnet/ip: $out"

out="$(run STACKWRANGLER_ECR_HOSTNAME_SUBNET=10.99.5.0/24 SNIPPET='sw_ecr_edge_env; echo "$STACKWRANGLER_ECR_HOSTNAME_IP"')"
[[ "$out" == "10.99.5.10" ]] || fail "IP not derived from subnet: $out"

out="$(run AWSBOX_ECR_HOSTNAME_SUBNET=10.98.0.0/24 AWSBOX_ECR_HOSTNAME_IP=10.98.0.20 SNIPPET='sw_ecr_edge_env; echo "$STACKWRANGLER_ECR_HOSTNAME_SUBNET $STACKWRANGLER_ECR_HOSTNAME_IP"')"
[[ "$out" == "10.98.0.0/24 10.98.0.20" ]] || fail "AWSBOX_* fallback / explicit IP: $out"

# Default: own <project>_ecr-host on the same subnet is reused, nothing else overlaps.
run SNIPPET='sw_ecr_edge_check' >/dev/null || fail "default subnet reported an overlap"

# Old default overlaps the leftover 172.31.0.0/16 → fail and name it.
out="$(run STACKWRANGLER_ECR_HOSTNAME_SUBNET=172.31.218.0/24 SNIPPET='sw_ecr_edge_check' || true)"
echo "$out" | grep -q "overlaps Docker network 'leftover-vpc' (172.31.0.0/16)" || fail "overlap not reported: $out"

# A wider leftover that contains the default also counts.
out="$(run STUB_LEFTOVER=10.0.0.0/8 SNIPPET='sw_ecr_edge_check' || true)"
echo "$out" | grep -q "overlaps Docker network 'leftover-vpc'" || fail "containing network not reported: $out"

# up runs the check before compose (checkout + image CLIs).
for f in bin/stackwrangler docker/bin/stackwrangler-image; do
	body="$(sed -n '/^cmd_up()/,/^}/p' "$ROOT/$f" | grep -v '^[[:space:]]*#')"
	c="$(echo "$body" | grep -n 'sw_ecr_edge_check' | head -1 | cut -d: -f1)"
	u="$(echo "$body" | grep -n 'COMPOSE\[@\]}" up -d' | head -1 | cut -d: -f1)"
	[[ -n "$c" && -n "$u" && "$c" -lt "$u" ]] || fail "$f: sw_ecr_edge_check not before compose up"
done

echo "ok ecr-edge-subnet"
