#!/usr/bin/env bash
# #83: App Runner stub — list-* returns empty (LocalEmu stub_providers; no CreateService).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

# Stub only implements List*; CreateService is 501 until a richer backend lands.
SVC_JSON="$(aws apprunner list-services --output json)"
CONN_JSON="$(aws apprunner list-connections --output json)"
ASC_JSON="$(aws apprunner list-auto-scaling-configurations --output json)"

python3 - "$SVC_JSON" "$CONN_JSON" "$ASC_JSON" <<'PY'
import json, sys
for label, raw in zip(("services", "connections", "autoScaling"), sys.argv[1:]):
    doc = json.loads(raw)
    key = {
        "services": "ServiceSummaryList",
        "connections": "ConnectionSummaryList",
        "autoScaling": "AutoScalingConfigurationSummaryList",
    }[label]
    if key not in doc:
        raise SystemExit(f"FAIL: missing {key} in list-{label}")
    if doc[key] is None:
        raise SystemExit(f"FAIL: {key} is null")
print("OK: apprunner list stubs (empty)")
PY
