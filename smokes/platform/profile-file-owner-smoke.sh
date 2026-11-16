#!/usr/bin/env bash
# #746: writing profile `local` as root (the Docker install's CLI) keeps the owner of the
# user's existing ~/.aws files, gives new ones to the dir's owner, keeps their other
# profiles, and leaves credentials 0600.
# Throwaway container; does not touch your ~/.aws.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

grep -q 'own_like_dir "$DATA"' "$ROOT/docker/bin/stackwrangler-image" || fail "image ensure_env does not hand ~/.stackwrangler files back"

out="$(docker run --rm -v "$ROOT:/sw:ro" alpine:3.20 sh -ec '
	apk add -q bash >/dev/null
	mkdir -p /h/.aws && printf "[default]\naws_access_key_id = mine\n" >/h/.aws/credentials
	chown -R 1000:1000 /h/.aws && chmod 644 /h/.aws/credentials
	HOME=/h ROOT=/sw bash /sw/bin/stackwrangler-profile write >/dev/null
	stat -c "%u %a %n" /h/.aws/credentials /h/.aws/config
	grep -c "^\[default\]" /h/.aws/credentials
')"
echo "$out" | grep -q '^1000 600 /h/.aws/credentials$' || fail "credentials not kept user-owned 0600: $out"
echo "$out" | grep -q '^1000 [0-7]* /h/.aws/config$' || fail "config not kept user-owned: $out"
[[ "$(echo "$out" | tail -1)" == 1 ]] || fail "existing [default] profile lost: $out"

echo "ok profile-file-owner"
