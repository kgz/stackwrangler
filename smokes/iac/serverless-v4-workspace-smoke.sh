#!/usr/bin/env bash
# Deploy examples/serverless-v4-workspace via yarn workspace package cwd (#468).
# Asserts stackwrangler mounts the workspace root when .bin/serverless is hoisted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v4-workspace"
SVC="$EX/packages/service"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
if [[ -z "${SERVERLESS_LICENSE_KEY:-}" && -n "${SERVERLESS_LOCAL_ONLY_LICENCE_KEY:-}" ]]; then
	export SERVERLESS_LICENSE_KEY="$SERVERLESS_LOCAL_ONLY_LICENCE_KEY"
fi
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-awsbox}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-awsboxawsbox}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
STAGE="local"
DEPLOY_BUCKET="awsbox-sls4-ws-deploy-${TS}"
SERVICE="awsbox-sls4-ws-${TS}"
STACK="${SERVICE}-${STAGE}"
KEEP="${AWSBOX_SLS_V4_KEEP:-0}"
OUT="$ROOT/.awsbox/serverless-v4-workspace-${TS}"
REMOVED=0
DEPLOYED=0
BUCKET_CREATED=0
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-300}"
FN_NAME="${SERVICE}-${STAGE}-greet"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWS_ENDPOINT_URL="$EP"
export AWSBOX_SLS4_WS_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLS4_WS_SERVICE="$SERVICE"
export AWSBOX_SLS4_WS_GREET_NAME="workspace-${TS}"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

require_sls_auth() {
	if [[ -n "${SERVERLESS_LICENSE_KEY:-}" || -n "${SERVERLESS_ACCESS_KEY:-}" ]]; then
		return 0
	fi
	echo "error: Serverless Framework v4 needs auth (SERVERLESS_ACCESS_KEY / LICENSE_KEY)." >&2
	echo "  See docs/serverless-awsbox.md" >&2
	exit 1
}

# Source mount-root helpers from stackwrangler without running the CLI.
sls_mount_root_of() {
	local cwd="$1"
	bash -c '
		set -euo pipefail
		# shellcheck disable=SC1090
		source <(sed -n "/^sls_is_workspace_root()/,/^}$/p; /^sls_serverless_owner()/,/^}$/p; /^sls_package_root()/,/^}$/p" "'"$ROOT"'/bin/stackwrangler")
		sls_package_root "'"$cwd"'"
	'
}

assert_workspace_mount() {
	local bin link mount
	bin="$SVC/node_modules/.bin/serverless"
	[[ -L "$bin" ]] || {
		echo "error: expected yarn-hoisted symlink at ${bin}" >&2
		ls -la "$SVC/node_modules/.bin" >&2 || true
		return 1
	}
	link="$(readlink "$bin")"
	case "$link" in
		*node_modules/serverless*) ;;
		*)
			echo "error: unexpected serverless bin link: ${link}" >&2
			return 1
			;;
	esac
	mount="$(sls_mount_root_of "$SVC")"
	[[ "$mount" == "$EX" ]] || {
		echo "error: sls_package_root should be workspace root ${EX}, got ${mount}" >&2
		return 1
	}
	echo "ok   sls_package_root mounts workspace root (bin → ${link})"
}

sls_run_timed() {
	local marker="$1"
	local log="$2"
	shift 2
	set +e
	(
		timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
			env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
			"$ROOT/bin/stackwrangler" sls --cwd "$SVC" -- "$@" --stage "$STAGE"
	) >"$log" 2>&1
	local rc=$?
	set -e
	if grep -qiE "$marker" "$log"; then
		sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | grep -v '^[[:space:]]*$' || cat "$log"
		return 0
	fi
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' >&2 || cat "$log" >&2 || true
	echo "error: serverless did not report '${marker}' (exit ${rc}, timeout ${SLS_TIMEOUT_SECS}s)" >&2
	return 1
}

cleanup() {
	if [[ "$KEEP" == "1" ]]; then
		return 0
	fi
	if [[ "$REMOVED" != "1" && "$DEPLOYED" == "1" ]]; then
		(
			timeout --signal=KILL 90 \
				env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
				"$ROOT/bin/stackwrangler" sls --cwd "$SVC" -- remove --stage "$STAGE" --verbose
		) >"$OUT/remove-cleanup.log" 2>&1 || true
	fi
	if [[ "$BUCKET_CREATED" == "1" ]]; then
		aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
	fi
	[[ -d "$OUT" ]] && rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"
require_sls_auth

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/stackwrangler up)" >&2
	exit 1
fi

echo "==> yarn install (workspace; hoists serverless .bin into packages/service)"
(cd "$EX" && yarn install --frozen-lockfile 2>/dev/null || yarn install)
assert_workspace_mount

echo "==> ensure aws-redirect + serverless --version via package cwd"
"$ROOT/bin/stackwrangler" sls --cwd "$SVC" -- --version >/dev/null
echo "ok   stackwrangler sls --cwd packages/service --version"

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
BUCKET_CREATED=1

echo "==> serverless deploy via --cwd packages/service (workspace mount)"
sls_run_timed 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy.log" deploy --verbose
DEPLOYED=1

echo "==> invoke Lambda (sibling @awsbox/ws-shared bundled)"
INV="$OUT/invoke.json"
aws lambda invoke --function-name "$FN_NAME" --payload '{}' "$INV" >/dev/null
BODY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$INV")"
MSG="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["message"])' "$BODY")"
EXPECT="hello workspace-${TS}"
[[ "$MSG" == "$EXPECT" ]] || {
	echo "error: invoke message want '${EXPECT}', got '${MSG}' (body=${BODY})" >&2
	exit 1
}
echo "ok   invoke → ${MSG}"

echo "==> serverless remove"
sls_run_timed 'Service removed|Stack remove finished|DELETE_COMPLETE|successfully removed' \
	"$OUT/remove.log" remove --verbose
REMOVED=1

aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
BUCKET_CREATED=0

echo "PASS serverless-v4-workspace-smoke (yarn workspace + sibling import)"
