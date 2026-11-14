#!/usr/bin/env bash
# Unit smoke for post-up IaC re-apply hook (#290). No LocalEmu / Docker required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bin/stackwrangler-env.sh"
# shellcheck disable=SC1091
source "$ROOT/bin/stackwrangler-dev-apply-hook.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

WORKDIR="$(mktemp -d /tmp/sw-dev-apply-smoke.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

export STACKWRANGLER_DEV_APPLY_HOOK_ROOT="$WORKDIR"
unset STACKWRANGLER_DEV_APPLY_HOOK AWSBOX_DEV_APPLY_HOOK
unset STACKWRANGLER_DEV_APPLY_HOOK_FILE AWSBOX_DEV_APPLY_HOOK_FILE

# No hook configured → no-op success
run_dev_apply_hook || fail "noop should succeed"
echo "ok: noop"

OK_HOOK="$WORKDIR/ok.sh"
cat >"$OK_HOOK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "apply-ok"
EOF
chmod +x "$OK_HOOK"

export STACKWRANGLER_DEV_APPLY_HOOK="$OK_HOOK"
out="$(run_dev_apply_hook 2>&1)" || fail "ok hook should succeed"
echo "$out" | grep -q 'dev apply hook:' || fail "missing hook banner"
echo "$out" | grep -q 'apply-ok' || fail "ok hook body missing"
unset STACKWRANGLER_DEV_APPLY_HOOK
echo "ok: STACKWRANGLER_DEV_APPLY_HOOK success"

FAIL_HOOK="$WORKDIR/fail.sh"
cat >"$FAIL_HOOK" <<'EOF'
#!/usr/bin/env bash
echo "apply-boom" >&2
exit 7
EOF
chmod +x "$FAIL_HOOK"

export AWSBOX_DEV_APPLY_HOOK="$FAIL_HOOK"
set +e
err="$(run_dev_apply_hook 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 7 ]] || fail "expected exit 7, got $rc"
echo "$err" | grep -q 'dev apply hook failed' || fail "missing failure message"
echo "$err" | grep -q 'apply-boom' || fail "hook stderr missing"
unset AWSBOX_DEV_APPLY_HOOK
echo "ok: AWSBOX_DEV_APPLY_HOOK failure propagates"

mkdir -p "$WORKDIR/.awsbox"
CFG_HOOK="$WORKDIR/from-cfg.sh"
cat >"$CFG_HOOK" <<'EOF'
#!/usr/bin/env bash
echo "from-config"
EOF
chmod +x "$CFG_HOOK"
printf '%s\n' "# demo hook" "$CFG_HOOK" >"$WORKDIR/.awsbox/dev-apply-hook"

out="$(run_dev_apply_hook 2>&1)" || fail "config-file hook should succeed"
echo "$out" | grep -q 'from-config' || fail "config hook body missing"
echo "ok: .awsbox/dev-apply-hook config"

MISSING="$WORKDIR/missing.sh"
export STACKWRANGLER_DEV_APPLY_HOOK="$MISSING"
set +e
err="$(run_dev_apply_hook 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing hook should fail"
echo "$err" | grep -q 'not found' || fail "missing-path message"
unset STACKWRANGLER_DEV_APPLY_HOOK
echo "ok: missing hook path fails"

echo "PASS: dev-apply-hook-smoke"
