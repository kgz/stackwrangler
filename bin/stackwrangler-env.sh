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
# .env load / exports) — used by bin/awsbox-profile and bin/stackwrangler.
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

if [[ "${STACKWRANGLER_ENV_DEFER:-0}" != "1" ]]; then
	stackwrangler_apply_defaults
fi
