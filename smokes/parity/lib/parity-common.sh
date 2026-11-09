# shellcheck shell=bash
# Shared helpers for dual-target parity checks (local LocalEmu + real AWS).
# Usage (near top of a check, after ROOT=):
#   PARITY_TARGET=local|real   # required (bin/parity sets this)
#   source "$ROOT/smokes/parity/lib/parity-common.sh"
#   parity_setup
#
# Provides: aws(), pass/fail, on_cleanup/run_cleanup, parity_account,
#           parity_resolve_kms_fixture (sets KEY_ID/KEY_ARN/CREATED_EPHEMERAL_CMK).

: "${ROOT:?ROOT must be set to the repo root}"
: "${PARITY_TARGET:?PARITY_TARGET must be local or real}"

PARITY_KEEP="${AWSBOX_PARITY_KEEP:-${PARITY_KEEP:-0}}"
PARITY_CLEANUP_CMDS=()
PARITY_FAIL=0
CREATED_EPHEMERAL_CMK=0
KEY_ID=""
KEY_ARN=""
PARITY_ACCOUNT=""
PARITY_REGION=""
PARITY_EP=""

parity_pass() { echo "OK: $*"; }
parity_fail() { echo "FAIL: $*" >&2; PARITY_FAIL=1; }

parity_die() {
	echo "FAIL: $*" >&2
	exit 1
}

on_cleanup() {
	PARITY_CLEANUP_CMDS+=("$*")
}

run_cleanup() {
	[[ "$PARITY_KEEP" == "1" ]] && {
		echo "KEEP=1 — skipped cleanup (${#PARITY_CLEANUP_CMDS[@]} cmds)"
		return 0
	}
	local i
	for ((i = ${#PARITY_CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
		eval "${PARITY_CLEANUP_CMDS[i]}" >/dev/null 2>&1 || true
	done
}

parity_setup() {
	trap run_cleanup EXIT

	case "$PARITY_TARGET" in
	local)
		# shellcheck disable=SC1091
		[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
		# shellcheck disable=SC1091
		source "$ROOT/smokes/lib/local-emu-env.sh"
		PARITY_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
		PARITY_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
		export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
		export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
		export AWS_DEFAULT_REGION="$PARITY_REGION"
		unset AWS_SESSION_TOKEN || true
		;;
	real)
		# Drop local stack creds so ~/.aws / env default principal is used.
		unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN || true
		unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ENDPOINT_URL || true
		export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-false}"
		PARITY_EP=""
		PARITY_REGION="${AWSBOX_PARITY_REGION:-${STACKWRANGLER_PARITY_REGION:-ap-southeast-2}}"
		export AWS_DEFAULT_REGION="$PARITY_REGION"
		export AWS_PAGER=""
		;;
	*)
		parity_die "PARITY_TARGET must be local or real (got '${PARITY_TARGET}')"
		;;
	esac

	PARITY_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
	[[ "$PARITY_ACCOUNT" =~ ^[0-9]{12}$ ]] || parity_die "caller account '${PARITY_ACCOUNT}' is not 12 digits"
	echo "==> parity target=${PARITY_TARGET} region=${PARITY_REGION} account=${PARITY_ACCOUNT}"
}

# aws wrapper: endpoint only for local.
aws() {
	if [[ "$PARITY_TARGET" == "local" ]]; then
		command aws --endpoint-url "$PARITY_EP" --region "$PARITY_REGION" "$@"
	else
		command aws --region "$PARITY_REGION" "$@"
	fi
}

# Resolve a customer CMK for checks that need kms:ResourceAliases / ViaService.
# Prefers fixture alias on real; creates ephemeral CMK on local (always) or when
# fixture missing on real (sets CREATED_EPHEMERAL_CMK=1 → 7d residual).
# Args: [fixture_alias_or_id]  default alias/sw-parity-fixture-trust-via
parity_resolve_kms_fixture() {
	local ref="${1:-alias/sw-parity-fixture-trust-via}"
	CREATED_EPHEMERAL_CMK=0
	KEY_ID=""
	KEY_ARN=""

	if [[ "$PARITY_TARGET" == "local" ]]; then
		KEY_ID="$(aws kms create-key --description "parity-local-${PARITY_TARGET}-$$" --query 'KeyMetadata.KeyId' --output text)"
		KEY_ARN="$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Arn' --output text)"
		CREATED_EPHEMERAL_CMK=1
		on_cleanup "aws kms schedule-key-deletion --key-id '$KEY_ID' --pending-window-in-days 7"
		echo "NOTE: local ephemeral CMK ${KEY_ID}"
		return 0
	fi

	if aws kms describe-key --key-id "$ref" >/dev/null 2>&1; then
		KEY_ID="$(aws kms describe-key --key-id "$ref" --query 'KeyMetadata.KeyId' --output text)"
		KEY_ARN="$(aws kms describe-key --key-id "$ref" --query 'KeyMetadata.Arn' --output text)"
		echo "NOTE: reusing fixture CMK ${ref} → ${KEY_ID} (no create / no schedule-deletion)"
		return 0
	fi

	echo "NOTE: fixture missing (${ref}); creating ephemeral CMK (7d residual)"
	KEY_ID="$(aws kms create-key --description "parity-ephemeral-$$" --query 'KeyMetadata.KeyId' --output text)"
	KEY_ARN="$(aws kms describe-key --key-id "$KEY_ID" --query 'KeyMetadata.Arn' --output text)"
	CREATED_EPHEMERAL_CMK=1
	on_cleanup "aws kms schedule-key-deletion --key-id '$KEY_ID' --pending-window-in-days 7; echo \"NOTE: KMS ${KEY_ID} PendingDeletion 7d\""
}

parity_finish() {
	[[ "$PARITY_FAIL" -eq 0 ]] || exit 1
}

# Real AWS IAM is eventually consistent after CreateRole / PutRolePolicy.
# Scheduler CreateSchedule validates trust immediately and fails until it propagates.
parity_wait_iam() {
	local seconds="${1:-10}"
	[[ "$PARITY_TARGET" == "real" ]] || return 0
	echo "NOTE: waiting ${seconds}s for IAM propagation (real)" >&2
	sleep "$seconds"
}

# Restore the pre-assume admin principal (default chain when env keys were unset).
parity_restore_admin() {
	local key="${1-}"
	local secret="${2-}"
	local token="${3-}"
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN || true
	if [[ -n "$key" ]]; then
		export AWS_ACCESS_KEY_ID="$key"
		export AWS_SECRET_ACCESS_KEY="$secret"
		[[ -n "$token" ]] && export AWS_SESSION_TOKEN="$token" || true
	fi
}
