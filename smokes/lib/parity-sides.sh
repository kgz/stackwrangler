# shellcheck shell=bash
# Shared dual-side (LocalEmu + real AWS) harness for smokes/parity/aws-parity-*.sh.
#
# Source after ROOT= and optional .env load. Define:
#   run_side <label>   # label is "local" or "real"; uses aws_cli()
# Then call:
#   parity_run_sides
#
# Env (same as existing aws-parity-* scripts):
#   AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1
#   AWSBOX_PARITY_REGION (default ap-southeast-2)
#   AWSBOX_PARITY_KEEP=1  (callers honour in their own teardown)
#
# aws_cli is redefined per side. Local side sources local-emu-env.sh.

parity_run_sides() {
	local LOCAL_EP LOCAL_KEY LOCAL_SECRET LOCAL_REGION REAL_REGION
	LOCAL_EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
	LOCAL_KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
	LOCAL_SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
	LOCAL_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
	REAL_REGION="${AWSBOX_PARITY_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"

	if [[ "${AWSBOX_PARITY_SKIP_LOCAL:-0}" != "1" ]]; then
		echo "======== LOCAL ========"
		# shellcheck disable=SC1091
		source "$ROOT/smokes/lib/local-emu-env.sh"
		export AWS_ACCESS_KEY_ID="$LOCAL_KEY"
		export AWS_SECRET_ACCESS_KEY="$LOCAL_SECRET"
		export AWS_DEFAULT_REGION="$LOCAL_REGION"
		aws_cli() {
			command aws --endpoint-url "$LOCAL_EP" --region "$LOCAL_REGION" "$@"
		}
		run_side "local"
	fi

	if [[ "${AWSBOX_PARITY_SKIP_REAL:-0}" != "1" ]]; then
		echo "======== REAL ========"
		export AWSBOX_ALLOW_REAL_AWS=1
		export STACKWRANGLER_ALLOW_REAL_AWS=1
		unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
		unset AWS_PROFILE AWS_DEFAULT_PROFILE
		export AWS_DEFAULT_REGION="$REAL_REGION"
		aws_cli() {
			command aws --region "$REAL_REGION" "$@"
		}
		echo "==> real caller"
		aws_cli sts get-caller-identity
		run_side "real"
	fi
}
