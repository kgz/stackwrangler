# shellcheck shell=bash
# Source from local smokes / local side of parity scripts.
# Hard-isolates the process from host ~/.aws so a missing --endpoint-url
# cannot create resources in a real account.
#
# Usage (near top of smoke, after ROOT=):
#   # shellcheck disable=SC1091
#   source "$ROOT/smokes/lib/local-emu-env.sh"
#
# Optional: AWSBOX_ALLOW_REAL_AWS=1 skips the guard (real-side parity only).

if [[ "${AWSBOX_ALLOW_REAL_AWS:-0}" == "1" ]]; then
	return 0 2>/dev/null || exit 0
fi

_sw_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$_sw_root/.env" ]] && set -a && source "$_sw_root/.env" && set +a

# Prefer STACKWRANGLER_* (canonical); AWSBOX_* still works.
export AWSBOX_ACCESS_KEY="${AWSBOX_ACCESS_KEY:-${STACKWRANGLER_ACCESS_KEY:-stackwrangler}}"
export AWSBOX_SECRET_KEY="${AWSBOX_SECRET_KEY:-${STACKWRANGLER_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWSBOX_REGION="${AWSBOX_REGION:-${STACKWRANGLER_REGION:-us-east-1}}"
export AWSBOX_IAM_ENDPOINT="${AWSBOX_IAM_ENDPOINT:-${STACKWRANGLER_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
export AWSBOX_ENDPOINT="${AWSBOX_ENDPOINT:-${STACKWRANGLER_ENDPOINT:-http://127.0.0.1:8333}}"

_ep_host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('${AWSBOX_IAM_ENDPOINT}').hostname or '')")"
case "$_ep_host" in
	127.0.0.1|localhost|::1|host.docker.internal) ;;
	*)
		echo "FATAL: refusing local smoke — AWSBOX_IAM_ENDPOINT host must be loopback (got '${AWSBOX_IAM_ENDPOINT}')." >&2
		echo "This guard exists so smokes never talk to real AWS by accident." >&2
		exit 2
		;;
esac

# Drop every credential-chain input that could reach a real account via ~/.aws.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_PROFILE_REGION
unset AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
export AWS_EC2_METADATA_DISABLED=true
# Env keys win over shared files; point shared files at nowhere so profile local cannot resurrect.
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null

export AWS_ACCESS_KEY_ID="$AWSBOX_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$AWSBOX_SECRET_KEY"
export AWS_DEFAULT_REGION="$AWSBOX_REGION"
# Do not export AWS_ENDPOINT_URL globally — S3 smokes need :8333 vs IAM :4566.
# Callers must pass --endpoint-url explicitly (existing pattern).

# Real IAM access keys always look like AKIA… / ASIA…. Local root keys must not.
case "$AWS_ACCESS_KEY_ID" in
	AKIA*|ASIA*)
		echo "FATAL: refusing local smoke — access key '${AWS_ACCESS_KEY_ID:0:8}…' looks like a real AWS key." >&2
		echo "Use STACKWRANGLER_ACCESS_KEY from .env (e.g. stackwrangler), not ~/.aws." >&2
		exit 2
		;;
esac

unset _sw_root _ep_host
