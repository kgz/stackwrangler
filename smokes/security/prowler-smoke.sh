#!/usr/bin/env bash
# Isolated Prowler run against LocalEmu. Fails if distinct failing API calls
# rise above / diverge from testdata/prowler/failing-api-baseline.txt (#196).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
ACCESS_KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
ACCOUNT_ID="${AWSBOX_ACCOUNT_ID:-000000000000}"
# Account-id virtual host form needs a wildcard host (not 127.0.0.1).
# Default: RFC 6761 *.localhost → loopback (no third-party DNS).
ENDPOINT="${AWSBOX_PROWLER_ENDPOINT:-http://awsbox.localhost:4566}"
BASELINE_FILE="${AWSBOX_PROWLER_BASELINE:-$ROOT/testdata/prowler/failing-api-baseline.txt}"
VENV_DIR="${AWSBOX_PROWLER_VENV:-$ROOT/.venv-prowler}"
PROWLER_VERSION="${AWSBOX_PROWLER_VERSION:-5.45.0}"
IMAGE_DIGEST_FILE="${AWSBOX_LOCALEMU_DIGEST_FILE:-$ROOT/localemu-patches/IMAGE_DIGEST}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-prowler-$$"
mkdir -p "$WORKDIR/out"
trap 'rm -rf "$WORKDIR"' EXIT

ensure_prowler() {
	if [[ -x "$VENV_DIR/bin/prowler" ]]; then
		return 0
	fi
	# Drop a half-built venv from a previous failed attempt (e.g. missing python3-venv).
	if [[ -d "$VENV_DIR" && ! -x "$VENV_DIR/bin/prowler" ]]; then
		echo "removing incomplete ${VENV_DIR}" >&2
		rm -rf "$VENV_DIR"
	fi
	echo "installing prowler==${PROWLER_VERSION} into ${VENV_DIR}" >&2
	if ! (
		set -e
		if command -v uv >/dev/null 2>&1; then
			# Prefer uv — avoids Debian/Ubuntu python3-venv package requirement.
			uv venv "$VENV_DIR"
			uv pip install --python "$VENV_DIR/bin/python" "prowler==${PROWLER_VERSION}"
		else
			python3 -m venv "$VENV_DIR"
			"$VENV_DIR/bin/pip" install -q "prowler==${PROWLER_VERSION}"
		fi
		[[ -x "$VENV_DIR/bin/prowler" ]]
	); then
		rm -rf "$VENV_DIR"
		echo "error: failed to install prowler==${PROWLER_VERSION}" >&2
		echo "hint: install uv (https://docs.astral.sh/uv/) or distro package python3-venv, then retry" >&2
		exit 1
	fi
}

write_isolated_aws() {
	cat >"$WORKDIR/credentials" <<EOF
[default]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
EOF
	cat >"$WORKDIR/config" <<EOF
[default]
region = ${REGION}
output = json
EOF
}

# Run a command with the same isolated AWS env as Prowler (no host ~/.aws).
isolated() {
	env -i \
		HOME="$WORKDIR" \
		PATH="/usr/bin:/bin:${PATH:-/usr/bin:/bin}" \
		TERM="${TERM:-dumb}" \
		LANG="${LANG:-C.UTF-8}" \
		AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
		AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
		AWS_DEFAULT_REGION="$REGION" \
		AWS_REGION="$REGION" \
		AWS_ENDPOINT_URL="$ENDPOINT" \
		AWS_SHARED_CREDENTIALS_FILE="$WORKDIR/credentials" \
		AWS_CONFIG_FILE="$WORKDIR/config" \
		AWS_EC2_METADATA_DISABLED=true \
		"$@"
}

check_endpoint_host() {
	local host
	host="$(python3 - <<PY
from urllib.parse import urlparse
print(urlparse("${ENDPOINT}").hostname or "")
PY
)"
	if [[ -z "$host" ]]; then
		echo "error: could not parse host from ENDPOINT=${ENDPOINT}" >&2
		exit 1
	fi
	if [[ "$host" == "127.0.0.1" || "$host" == "localhost" ]]; then
		echo "error: ENDPOINT host '${host}' breaks S3 Control (<account-id>.${host} will not resolve)" >&2
		echo "hint: default is http://awsbox.localhost:4566 — run: ./bin/stackwrangler-hosts print|apply" >&2
		echo "hint: or set AWSBOX_PROWLER_ENDPOINT to a host that supports <account-id>.<host>" >&2
		exit 1
	fi
	# Prefer IPv4 — LocalEmu compose binds 127.0.0.1 only.
	if ! AWSBOX_CHECK_HOST="$host" AWSBOX_CHECK_ACCOUNT="$ACCOUNT_ID" python3 - <<'PY'
import os, socket, sys

host = os.environ["AWSBOX_CHECK_HOST"]
account = os.environ["AWSBOX_CHECK_ACCOUNT"]
try:
    socket.getaddrinfo(host, 4566, socket.AF_INET)
except OSError as e:
    print(f"error: cannot resolve {host!r} (AF_INET): {e}", file=sys.stderr)
    sys.exit(1)
acct = f"{account}.{host}"
try:
    socket.getaddrinfo(acct, 4566, socket.AF_INET)
except OSError as e:
    print(f"error: cannot resolve account host {acct!r}: {e}", file=sys.stderr)
    sys.exit(1)
PY
	then
		echo "hint: ./bin/stackwrangler-hosts print   # exact /etc/hosts line" >&2
		echo "hint: ./bin/stackwrangler-hosts apply   # sudo append (see docs/prowler.md)" >&2
		echo "hint: AWSBOX_PROWLER_ENDPOINT=http://…  # override (e.g. local dnsmasq wildcard)" >&2
		exit 1
	fi
}

check_localemu_digest() {
	[[ -f "$IMAGE_DIGEST_FILE" ]] || return 0
	local want cid digests
	want="$(grep -E '^sha256:' "$IMAGE_DIGEST_FILE" | head -1 | tr -d '[:space:]')"
	[[ -n "$want" ]] || return 0
	cid="$(docker compose -f "$ROOT/docker-compose.yml" ps -q localstack 2>/dev/null || true)"
	[[ -n "$cid" ]] || {
		echo "error: LocalEmu container not running (need ./bin/awsbox up)" >&2
		exit 1
	}
	local img
	img="$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || true)"
	digests="$(docker image inspect "$img" --format '{{range .RepoDigests}}{{println .}}{{end}}{{.Id}}' 2>/dev/null || true)"
	if ! grep -qF "$want" <<<"$digests"; then
		echo "error: running LocalEmu image does not match pinned ${want}" >&2
		echo "running image ${img}:" >&2
		echo "$digests" >&2
		echo "hint: bump localemu-patches/IMAGE_DIGEST + compose image together after verifying patches" >&2
		exit 1
	fi
}

# Extract distinct failing API operations from Prowler ERROR logs.
parse_failing_apis() {
	python3 - <<'PY' "$1"
import re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
found: set[str] = set()

for m in re.finditer(
    r"when calling the ([A-Za-z0-9]+) operation", text, re.I
):
    found.add(m.group(1))

for m in re.finditer(
    r"exception while calling\s+([a-z0-9_-]+)\.([A-Za-z0-9]+)", text, re.I
):
    found.add(f"{m.group(1)}.{m.group(2)}")

for m in re.finditer(r"Failed to resolve ['\"]([^'\"]+)['\"]", text, re.I):
    found.add(f"DNS:{m.group(1)}")
for m in re.finditer(
    r"Could not connect to the endpoint URL:\s*[\"']([^\"']+)[\"']", text, re.I
):
    found.add(f"ENDPOINT:{m.group(1)}")

for m in re.finditer(
    r"The ([A-Za-z0-9_]+) action has not been implemented", text
):
    found.add(m.group(1))

ignore = {"DescribeOrganization", "GetPublicAccessBlock"}
# GetPublicAccessBlock NoSuch… is a valid AWS empty-account response, not a gap.
found = {
    t
    for t in found
    if t not in ignore and not (t.islower() or "_" in t)
}

print("\n".join(sorted(found)))
PY
}

baseline_tokens() {
	grep -ve '^[[:space:]]*#' -e '^[[:space:]]*$' "$BASELINE_FILE" | sort -u || true
}

ensure_prowler
write_isolated_aws
check_endpoint_host
check_localemu_digest

LOG_FILE="$WORKDIR/prowler.log"
set +e
isolated \
	"$VENV_DIR/bin/prowler" aws \
	--no-banner \
	--log-level ERROR \
	-f "$REGION" \
	--scan-unused-services \
	--service s3 iam ec2 rds ssm cloudwatch cloudtrail organizations backup \
	awslambda apigateway batch autoscaling \
	--output-directory "$WORKDIR/out" \
	--output-formats csv \
	--ignore-exit-code-3 \
	>"$LOG_FILE" 2>&1
PROWLER_RC=$?
set -e

if [[ "$PROWLER_RC" -ne 0 ]]; then
	echo "error: prowler exited ${PROWLER_RC} (expected 0 with --ignore-exit-code-3)" >&2
	tail -n 40 "$LOG_FILE" >&2 || true
	exit 1
fi

FAILING_FILE="$WORKDIR/failing.txt"
parse_failing_apis "$LOG_FILE" | sed '/^$/d' >"$FAILING_FILE"
COUNT="$(wc -l <"$FAILING_FILE" | tr -d ' ')"

echo "prowler exit=${PROWLER_RC} distinct_failing_apis=${COUNT} endpoint=${ENDPOINT}"
if [[ "$COUNT" -gt 0 ]]; then
	echo "--- failing API tokens ---"
	cat "$FAILING_FILE"
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
	echo "error: missing baseline ${BASELINE_FILE}" >&2
	exit 1
fi

BASELINE_SORTED="$WORKDIR/baseline.txt"
baseline_tokens >"$BASELINE_SORTED"
BASELINE_COUNT="$(wc -l <"$BASELINE_SORTED" | tr -d ' ')"

# Set ratchet: fail on any new token (not only count growth).
NEW_TOKENS="$(comm -13 "$BASELINE_SORTED" <(sort -u "$FAILING_FILE") || true)"
if [[ -n "$NEW_TOKENS" ]]; then
	echo "error: new failing API tokens vs baseline ${BASELINE_FILE}:" >&2
	printf '%s\n' "$NEW_TOKENS" >&2
	exit 1
fi

if grep -qE 'DNS:.*127\.0\.0\.1|ENDPOINT:.*[0-9]+\.127\.0\.0\.1' "$FAILING_FILE"; then
	echo "error: S3 Control still using unresolved <account>.127.0.0.1 host" >&2
	exit 1
fi

# Spot-check S3 Control under the same env -i isolation as the scan.
isolated aws --endpoint-url "$ENDPOINT" s3control get-public-access-block \
	--account-id "$ACCOUNT_ID" >/dev/null 2>"$WORKDIR/pab.err" && PAB_RC=0 || PAB_RC=$?
if [[ "$PAB_RC" -ne 0 ]]; then
	# Unset config → NoSuchPublicAccessBlockConfiguration is the AWS-shaped empty state.
	if ! grep -q 'NoSuchPublicAccessBlockConfiguration' "$WORKDIR/pab.err"; then
		cat "$WORKDIR/pab.err" >&2
		echo "error: get-public-access-block failed unexpectedly" >&2
		exit 1
	fi
fi
isolated aws --endpoint-url "$ENDPOINT" s3control put-public-access-block \
	--account-id "$ACCOUNT_ID" \
	--public-access-block-configuration \
	"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
	>/dev/null
isolated aws --endpoint-url "$ENDPOINT" s3control get-public-access-block \
	--account-id "$ACCOUNT_ID" >/dev/null
isolated aws --endpoint-url "$ENDPOINT" s3control list-access-points \
	--account-id "$ACCOUNT_ID" >/dev/null
isolated aws --endpoint-url "$ENDPOINT" s3control list-multi-region-access-points \
	--account-id "$ACCOUNT_ID" >/dev/null

echo "OK: prowler-smoke (failing=${COUNT} baseline=${BASELINE_COUNT} set-ok endpoint=${ENDPOINT})"
