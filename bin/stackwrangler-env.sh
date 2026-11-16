#!/usr/bin/env bash
# Shared STACKWRANGLER_* / AWSBOX_* credential resolution for smokes and bins.
#
# Prefer STACKWRANGLER_*, else AWSBOX_*, else stackwrangler product defaults
# (see .env.example). Source after ROOT is set to the repo root when possible;
# otherwise ROOT is derived from this file's location.
#
#   # shellcheck disable=SC1091
#   source "$ROOT/bin/stackwrangler-env.sh"
#
# Set STACKWRANGLER_ENV_DEFER=1 before sourcing to only define sw_env (no
# .env load / exports) — used by bin/stackwrangler-profile and bin/stackwrangler.
#
# Set STACKWRANGLER_ENV_SKIP_DOTENV=1 to resolve from the current environment
# only (caller already sourced .env, or wants process env to win).

# STACKWRANGLER_* wins; else AWSBOX_* (old .env); else default.
sw_env() {
	local sw_name="$1" ab_name="$2" default="${3:-}"
	local sw_val ab_val
	sw_val="${!sw_name-}"
	ab_val="${!ab_name-}"
	if [[ -n "$sw_val" ]]; then
		printf '%s' "$sw_val"
	elif [[ -n "$ab_val" ]]; then
		printf '%s' "$ab_val"
	else
		printf '%s' "$default"
	fi
}

stackwrangler_apply_defaults() {
	local root dotenv
	root="${ROOT:-}"
	if [[ -z "$root" ]]; then
		root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	fi
	if [[ "${STACKWRANGLER_ENV_SKIP_DOTENV:-0}" != "1" ]]; then
		dotenv="$root/.env"
		if [[ -f "$dotenv" ]]; then
			set -a
			# shellcheck disable=SC1091
			source "$dotenv"
			set +a
		fi
	fi

	export STACKWRANGLER_ACCESS_KEY
	export STACKWRANGLER_SECRET_KEY
	export STACKWRANGLER_REGION
	export STACKWRANGLER_ENDPOINT
	export STACKWRANGLER_IAM_ENDPOINT
	STACKWRANGLER_ACCESS_KEY="$(sw_env STACKWRANGLER_ACCESS_KEY AWSBOX_ACCESS_KEY stackwrangler)"
	STACKWRANGLER_SECRET_KEY="$(sw_env STACKWRANGLER_SECRET_KEY AWSBOX_SECRET_KEY stackwranglerstackwrangler)"
	STACKWRANGLER_REGION="$(sw_env STACKWRANGLER_REGION AWSBOX_REGION us-east-1)"
	STACKWRANGLER_ENDPOINT="$(sw_env STACKWRANGLER_ENDPOINT AWSBOX_ENDPOINT http://127.0.0.1:8333)"
	STACKWRANGLER_IAM_ENDPOINT="$(sw_env STACKWRANGLER_IAM_ENDPOINT AWSBOX_IAM_ENDPOINT http://127.0.0.1:4566)"

	# Keep AWSBOX_* aligned so child processes / older call sites stay consistent.
	export AWSBOX_ACCESS_KEY="$STACKWRANGLER_ACCESS_KEY"
	export AWSBOX_SECRET_KEY="$STACKWRANGLER_SECRET_KEY"
	export AWSBOX_REGION="$STACKWRANGLER_REGION"
	export AWSBOX_ENDPOINT="$STACKWRANGLER_ENDPOINT"
	export AWSBOX_IAM_ENDPOINT="$STACKWRANGLER_IAM_ENDPOINT"
}

# ECR repositoryUri edge network (#218). Default sits outside Docker's default
# address pools (172.17-31/16, 192.168/16), which it used to clash with (#750).
# The edge IP is derived from the subnet (host .10) unless set explicitly.
sw_ecr_edge_env() {
	local subnet ip net
	subnet="$(sw_env STACKWRANGLER_ECR_HOSTNAME_SUBNET AWSBOX_ECR_HOSTNAME_SUBNET 10.254.218.0/24)"
	ip="$(sw_env STACKWRANGLER_ECR_HOSTNAME_IP AWSBOX_ECR_HOSTNAME_IP "")"
	if [[ -z "$ip" ]]; then
		net="${subnet%/*}"
		ip="${net%.*}.10"
	fi
	export STACKWRANGLER_ECR_HOSTNAME_SUBNET="$subnet" STACKWRANGLER_ECR_HOSTNAME_IP="$ip"
}

_sw_ip4_int() { # a.b.c.d → integer
	local IFS=. a b c d
	read -r a b c d <<<"$1"
	echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

_sw_cidr_overlap() { # cidr cidr → 0 if they overlap
	local a="$1" b="$2" pa pb p mask
	pa="${a#*/}" pb="${b#*/}"
	p=$((pa < pb ? pa : pb))
	mask=$(((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF))
	(($(($(_sw_ip4_int "${a%/*}") & mask)) == $(($(_sw_ip4_int "${b%/*}") & mask))))
}

# Fail before compose when another Docker network already holds the ECR edge subnet.
# An existing <project>_ecr-host on exactly this subnet is our own and is reused.
sw_ecr_edge_check() {
	local subnet name cidr
	sw_ecr_edge_env
	subnet="$STACKWRANGLER_ECR_HOSTNAME_SUBNET"
	command -v docker >/dev/null 2>&1 || return 0
	while read -r name cidr; do
		[[ -n "$cidr" && "$cidr" == *.*/* ]] || continue
		[[ "$name" == *_ecr-host && "$cidr" == "$subnet" ]] && continue
		if _sw_cidr_overlap "$subnet" "$cidr"; then
			echo "error: ECR edge subnet ${subnet} overlaps Docker network '${name}' (${cidr})." >&2
			echo "  Set STACKWRANGLER_ECR_HOSTNAME_SUBNET to a free /24 in .env (the edge IP follows it)," >&2
			echo "  or remove '${name}' if it is a leftover." >&2
			return 1
		fi
	done < <(docker network ls -q 2>/dev/null | xargs -r docker network inspect \
		-f '{{.Name}}{{range .IPAM.Config}} {{.Subnet}}{{end}}' 2>/dev/null |
		awk '{for (i = 2; i <= NF; i++) print $1, $i}')
}

if [[ "${STACKWRANGLER_ENV_DEFER:-0}" != "1" ]]; then
	stackwrangler_apply_defaults
fi
