#!/usr/bin/env bash
# Integration Lambda → Secrets Manager (per-stage OAuth client) → token fetch → POST document to an external API.
# Mock "ERP" API runs on the host, bound to the docker bridge gateway only (what host-gateway maps to).
# Happy: one token request with the secret's creds + one document POST with that bearer token.
# Stage isolation: stage=b uses b's credentials. Env var BASE_URL drives the call (flip to a 2nd mock).
# Sad/authz: role without secretsmanager:GetSecretValue → Lambda fails, mock sees NO requests.
# Sad/other: wrong client secret → mock 401, Lambda reports failure and does not post the document.
# Needs AWSBOX_LAMBDA_DOCKER_FLAGS to map host.docker.internal (default; docs/lambda-vpc.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
FN="awsbox-oauth-${TS}"
FN_DENY="awsbox-oauth-deny-${TS}"
ROLE="awsbox-oauth-role-${TS}"
ROLE_DENY="awsbox-oauth-norole-${TS}"
SECRETS=()
TMP="$(mktemp -d)"
PIDS=()
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN_DENY" >/dev/null 2>&1 || true
	for s in "${SECRETS[@]:-}"; do
		[[ -n "$s" ]] && aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery >/dev/null 2>&1 || true
	done
	aws iam delete-role-policy --role-name "$ROLE" --policy-name sm-read >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE_DENY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Bind only the docker bridge gateway (host-gateway target); never 0.0.0.0.
BIND="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
[[ -n "$BIND" ]] || { echo "FAIL: cannot determine docker bridge gateway" >&2; exit 1; }

cat >"$TMP/mock.py" <<'PY'
import base64, json, secrets, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
bind, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CLIENTS = json.loads(sys.argv[4])  # client_id -> client_secret
tokens = {}
def rec(**kw):
    with open(log, "a") as f: f.write(json.dumps(kw) + "\n")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        if self.path == "/oauth2/access_token":
            form = urllib.parse.parse_qs(body)
            cid = (form.get("client_id") or [None])[0]; sec = (form.get("client_secret") or [None])[0]
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Basic "):
                cid, _, sec = base64.b64decode(auth[6:]).decode().partition(":")
            ok = form.get("grant_type") == ["client_credentials"] and cid in CLIENTS and CLIENTS[cid] == sec
            rec(kind="token", client_id=cid, ok=ok)
            if not ok: return self.reply(401, {"error": "invalid_client"})
            t = "tok-" + secrets.token_hex(8); tokens[t] = cid
            return self.reply(200, {"access_token": t, "token_type": "Bearer", "expires_in": 3600})
        if self.path == "/LoadDocumentFile":
            a = self.headers.get("Authorization", ""); t = a[7:] if a.startswith("Bearer ") else None
            ok = t in tokens
            rec(kind="doc", ok=ok, client_id=tokens.get(t), body=body)
            return self.reply(200 if ok else 401, {"status": "loaded"} if ok else {"error": "unauthorized"})
        self.reply(404, {})
HTTPServer((bind, port), H).serve_forever()
PY

free_port() { python3 -c 'import socket,sys; s=socket.socket(); s.bind((sys.argv[1],0)); print(s.getsockname()[1])' "$BIND"; }
CLIENTS_JSON='{"acme-a":"secret-a","acme-b":"secret-b"}'
start_mock() { # name -> sets PORT_<name>, LOG_<name>
	local p; p="$(free_port)"
	: >"$TMP/$1.log"
	python3 "$TMP/mock.py" "$BIND" "$p" "$TMP/$1.log" "$CLIENTS_JSON" >/dev/null 2>&1 &
	PIDS+=("$!")
	for _ in $(seq 1 30); do
		python3 -c 'import socket,sys; socket.create_connection((sys.argv[1],int(sys.argv[2])),1)' "$BIND" "$p" 2>/dev/null && break
		sleep 0.2
	done
	eval "PORT_$1=$p"
}
start_mock m1
start_mock m2
URL1="http://host.docker.internal:${PORT_m1}"
URL2="http://host.docker.internal:${PORT_m2}"
reqs() { python3 -c 'import json,sys; [print(l.strip()) for l in open(sys.argv[1])]' "$TMP/$1.log"; }
nreq() { wc -l <"$TMP/$1.log" | tr -d ' '; }

mkdir -p "$ROOT/.awsbox"
ZIP="$TMP/fn.zip"
python3 - "$ZIP" <<'PY'
import sys, zipfile
code = b"""const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
exports.handler = async (event) => {
  const base = process.env.BASE_URL;
  try {
    const sm = new SecretsManagerClient({ region: process.env.AWS_REGION || "us-east-1" });
    const r = await sm.send(new GetSecretValueCommand({ SecretId: `integration/${event.stage}/oauth` }));
    const { client_id, client_secret } = JSON.parse(r.SecretString);
    const t = await fetch(`${base}/oauth2/access_token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded",
                 Authorization: "Basic " + Buffer.from(`${client_id}:${client_secret}`).toString("base64") },
      body: "grant_type=client_credentials",
      signal: AbortSignal.timeout(5000),
    });
    if (!t.ok) return { ok: false, step: "token", status: t.status };
    const { access_token } = await t.json();
    const d = await fetch(`${base}/LoadDocumentFile`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${access_token}` },
      body: JSON.stringify({ doc: event.doc }),
      signal: AbortSignal.timeout(5000),
    });
    return { ok: d.ok, step: "document", status: d.status };
  } catch (err) {
    return { ok: false, step: "error", name: err.name || null, message: String(err.message || err) };
  }
};
"""
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

# Secrets: stage a, stage b, stage bad (wrong client secret).
# Real names are fixed by the contract (integration/<stage>/oauth); stage names carry TS for uniqueness.
SA="a${TS}"; SB="b${TS}"; SBAD="bad${TS}"
SECRETS=("integration/${SA}/oauth" "integration/${SB}/oauth" "integration/${SBAD}/oauth")
mk_secret_raw() { aws secretsmanager create-secret --name "integration/$1/oauth" --secret-string "$2" >/dev/null; }
mk_secret_raw "$SA" '{"client_id":"acme-a","client_secret":"secret-a"}'
mk_secret_raw "$SB" '{"client_id":"acme-b","client_secret":"secret-b"}'
mk_secret_raw "$SBAD" '{"client_id":"acme-a","client_secret":"WRONG"}'

aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name sm-read --policy-document \
	'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"*"}]}'
aws iam create-role --role-name "$ROLE_DENY" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
ROLE_DENY_ARN="$(aws iam get-role --role-name "$ROLE_DENY" --query Role.Arn --output text)"

mk_fn() { # name role-arn
	aws lambda create-function --function-name "$1" --runtime nodejs20.x --role "$2" \
		--handler index.handler --zip-file "fileb://${ZIP}" --timeout 30 \
		--environment "Variables={BASE_URL=${URL1}}" >/dev/null
	local s=""
	for _ in $(seq 1 60); do
		s="$(aws lambda get-function --function-name "$1" --query Configuration.State --output text 2>/dev/null || echo Pending)"
		[[ "$s" == Active ]] && return 0
		sleep 2
	done
	echo "FAIL: $1 never Active" >&2; exit 1
}
mk_fn "$FN" "$ROLE_ARN"
mk_fn "$FN_DENY" "$ROLE_DENY_ARN"

invoke() { # fn stage -> prints payload
	aws lambda invoke --function-name "$1" --cli-binary-format raw-in-base64-out \
		--payload "{\"stage\":\"$2\",\"doc\":\"doc-$2-${TS}\"}" "$TMP/out.json" >/dev/null
	cat "$TMP/out.json"
}

FAILS=0
check() { # label cond(0/1)
	if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS+1)); fi
}
# pyexpr: evaluate python bool over mock log (list L of dicts) and payload P
pyc() { python3 -c 'import json,sys
L=[json.loads(l) for l in open(sys.argv[1])]; P=json.loads(sys.argv[2])
sys.exit(0 if eval(sys.argv[3]) else 1)' "$TMP/$1.log" "$2" "$3"; }

# 1. happy, stage a
P="$(invoke "$FN" "$SA")"; echo "payload a: $P"
pyc m1 "$P" 'P["ok"] and len(L)==2 and L[0]["kind"]=="token" and L[0]["client_id"]=="acme-a" and L[0]["ok"] and L[1]["kind"]=="doc" and L[1]["ok"] and L[1]["client_id"]=="acme-a" and json.loads(L[1]["body"])["doc"].startswith("doc-a")'
check "happy: one token request with secret creds + one document POST with valid bearer" $?

# 2. stage isolation
: >"$TMP/m1.log"
P="$(invoke "$FN" "$SB")"; echo "payload b: $P"
pyc m1 "$P" 'P["ok"] and len(L)==2 and L[0]["client_id"]=="acme-b" and L[1]["client_id"]=="acme-b" and json.loads(L[1]["body"])["doc"].startswith("doc-b")'
check "stage isolation: stage=b used b's credentials (not a's)" $?

# 3. env var drives the call
aws lambda update-function-configuration --function-name "$FN" --environment "Variables={BASE_URL=${URL2}}" >/dev/null
for _ in $(seq 1 30); do
	[[ "$(aws lambda get-function-configuration --function-name "$FN" --query LastUpdateStatus --output text)" != InProgress ]] && break
	sleep 1
done
: >"$TMP/m1.log"; : >"$TMP/m2.log"
P="$(invoke "$FN" "$SA")"; echo "payload env flip: $P"
[[ "$(nreq m1)" == 0 && "$(nreq m2)" == 2 ]] && pyc m2 "$P" 'P["ok"]'
check "env var BASE_URL drives the call (flipped to 2nd mock: m2 saw 2 requests, m1 none)" $?

# 4. sad other: wrong client secret
: >"$TMP/m1.log"
aws lambda update-function-configuration --function-name "$FN" --environment "Variables={BASE_URL=${URL1}}" >/dev/null
for _ in $(seq 1 30); do
	[[ "$(aws lambda get-function-configuration --function-name "$FN" --query LastUpdateStatus --output text)" != InProgress ]] && break
	sleep 1
done
P="$(invoke "$FN" "$SBAD")"; echo "payload wrong secret: $P"
pyc m1 "$P" 'not P["ok"] and P["step"]=="token" and P["status"]==401 and len(L)==1 and L[0]["kind"]=="token" and not L[0]["ok"] and not any(r["kind"]=="doc" for r in L)'
check "sad: wrong client secret -> mock 401, Lambda reports failure, no document posted" $?

# 5. sad authz: role without GetSecretValue
: >"$TMP/m1.log"
P="$(invoke "$FN_DENY" "$SA")"; echo "payload no-perm: $P"
echo "$P" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' && [[ "$(nreq m1)" == 0 ]] && pyc m1 "$P" 'not P["ok"] and P["step"]=="error"'
check "sad/authz: role without secretsmanager:GetSecretValue -> Lambda fails, mock saw no requests" $?

[[ "$FAILS" == 0 ]] || { echo "FAILED: ${FAILS} check(s)" >&2; exit 1; }
echo "OK: Lambda secret + OAuth to external API (${FN})"
