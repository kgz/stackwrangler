#!/usr/bin/env bash
# Route 53 public hosted zone + A / A-alias / CNAME records (#56).
# Creates a public zone, UPSERTs records, list-resource-record-sets shows them,
# dig @127.0.0.1 inside the emulator resolves. Optional: profile local list.
# Private zones: see ./smokes/networking/r53-private-smoke.sh · docs/r53-private.md
# Slice: examples/serverless-v3-rest/slices/dns/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SLICE="$ROOT/examples/serverless-v3-rest/slices/dns"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

HOST_PORT="${AWSBOX_R53Z_HOST_PORT:-${AWSBOX_LOCALEMU_HOST_PORT:-24556}}"
EP="${AWSBOX_R53Z_ENDPOINT:-http://127.0.0.1:${HOST_PORT}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
KEEP="${AWSBOX_R53Z_KEEP:-0}"
RECREATE="${AWSBOX_R53Z_RECREATE:-1}"
PROJECT="${AWSBOX_R53Z_COMPOSE_PROJECT:-awsl-wt-56-r53}"
S3_PORT="${AWSBOX_R53Z_S3_HOST_PORT:-28356}"
ECR_PORT="${AWSBOX_R53Z_ECR_HOST_PORT:-25056}"
SFTP_PORT="${AWSBOX_R53Z_SFTP_HOST_PORT:-22256}"
CREDS_PORT="${AWSBOX_R53Z_ECS_CREDS_PORT:-24572}"
ZONE_NAME="${AWSBOX_R53Z_ZONE:-example-${TS}.test}"
PROFILE_CHECK="${AWSBOX_R53Z_PROFILE_LIST:-1}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_LOCALEMU_HOST_PORT="$HOST_PORT"
export AWSBOX_S3_HOST_PORT="$S3_PORT"
export AWSBOX_ECR_HOST_PORT="$ECR_PORT"
export AWSBOX_SFTP_HOST_PORT="$SFTP_PORT"
export AWSBOX_ECS_CREDS_PORT="$CREDS_PORT"
export AWSBOX_SECRET_KEY="$SECRET"
export AWSBOX_ACCESS_KEY="$KEY"

COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
ZONE_ID=""
PRIV_ZONE_ID=""
PRIV_VPC=""
DENY_USER=""
DENY_KEY=""
POLICY_ARN=""
LS=""
OWNED_STACK=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup_zone_records() {
	local zone="$1"
	[[ -n "$zone" ]] || return 0
	python3 - "$zone" "$EP" "$REGION" <<'PY' || true
import json, subprocess, sys
zone, ep, region = sys.argv[1:]
out = subprocess.check_output([
    "aws", "--endpoint-url", ep, "--region", region,
    "route53", "list-resource-record-sets", "--hosted-zone-id", zone, "--output", "json",
], text=True)
changes = []
for rr in json.loads(out).get("ResourceRecordSets") or []:
    if rr.get("Type") in {"NS", "SOA"}:
        continue
    changes.append({"Action": "DELETE", "ResourceRecordSet": rr})
if changes:
    subprocess.call([
        "aws", "--endpoint-url", ep, "--region", region, "route53",
        "change-resource-record-sets", "--hosted-zone-id", zone,
        "--change-batch", json.dumps({"Changes": changes}),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

cleanup() {
	local rc=$?
	set +e
	if [[ "$KEEP" == "1" ]]; then
		echo "KEEP=1; leaving resources (exit $rc)"
		exit "$rc"
	fi
	cleanup_zone_records "$ZONE_ID"
	[[ -n "$ZONE_ID" ]] && aws route53 delete-hosted-zone --id "$ZONE_ID" >/dev/null 2>&1
	cleanup_zone_records "$PRIV_ZONE_ID"
	[[ -n "$PRIV_ZONE_ID" ]] && aws route53 delete-hosted-zone --id "$PRIV_ZONE_ID" >/dev/null 2>&1
	[[ -n "$PRIV_VPC" ]] && aws ec2 delete-vpc --vpc-id "$PRIV_VPC" >/dev/null 2>&1
	if [[ -n "$POLICY_ARN" && -n "$DENY_USER" ]]; then
		aws iam detach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1
		aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1
	fi
	if [[ -n "$DENY_KEY" && -n "$DENY_USER" ]]; then
		aws iam delete-access-key --user-name "$DENY_USER" --access-key-id "$DENY_KEY" >/dev/null 2>&1
	fi
	[[ -n "$DENY_USER" ]] && aws iam delete-user --user-name "$DENY_USER" >/dev/null 2>&1
	if [[ "$OWNED_STACK" == "1" ]]; then
		"${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
	fi
	exit "$rc"
}
trap cleanup EXIT

echo "endpoint ${EP} project ${PROJECT}"
OWNED_STACK=1
if [[ "$RECREATE" == "1" ]]; then
	"${COMPOSE[@]}" up -d --force-recreate
else
	"${COMPOSE[@]}" up -d
fi
for _ in $(seq 1 90); do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
	[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && break
	sleep 2
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
[[ "$code" =~ ^[12345][0-9][0-9]$ ]] || fail "LocalEmu not ready at ${EP} (${code})"

LS="$("${COMPOSE[@]}" ps -q localstack)"
[[ -n "$LS" ]] || fail "localstack container missing"
for _ in $(seq 1 40); do
	docker exec "$LS" grep -q "private DNS resolver starting" /tmp/vpce-resolver.log 2>/dev/null && break
	sleep 1
done
docker exec "$LS" grep -q "private DNS resolver starting" /tmp/vpce-resolver.log \
	|| fail "resolver did not start ($(docker exec "$LS" cat /tmp/vpce-resolver.log 2>/dev/null | tail -20))"
for _ in $(seq 1 20); do
	docker exec "$LS" grep -q "UDP/53 on 127.0.0.1" /tmp/vpce-resolver.log 2>/dev/null && break
	sleep 1
done

# Resolve A via dig (if present) or a tiny UDP client — always @127.0.0.1 in-container.
resolve_a() {
	local name="$1"
	docker exec -i "$LS" python3 - "$name" <<'PY'
import socket, struct, sys

name = sys.argv[1].rstrip(".") + "."

def enc(n: str) -> bytes:
    return b"".join(bytes([len(p)]) + p.encode() for p in n.rstrip(".").split(".")) + b"\x00"

q = struct.pack("!HHHHHH", 0x56A1, 0x0100, 1, 0, 0, 0) + enc(name) + struct.pack("!HH", 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
sock.sendto(q, ("127.0.0.1", 53))
data, _ = sock.recvfrom(4096)
ancount = struct.unpack("!H", data[6:8])[0]
off = 12
while data[off] != 0:
    off += 1 + data[off]
off += 5
addrs: list[str] = []
for _ in range(ancount):
    if data[off] & 0xC0 == 0xC0:
        off += 2
    else:
        while data[off] != 0:
            off += 1 + data[off]
        off += 1
    typ, _c, _t, rdlen = struct.unpack("!HHIH", data[off : off + 10])
    off += 10
    rdata = data[off : off + rdlen]
    off += rdlen
    if typ == 1 and rdlen == 4:
        addrs.append(socket.inet_ntoa(rdata))
print("\n".join(addrs))
PY
}

# --- public zone + records ---
ZONE_ID="$(aws route53 create-hosted-zone \
	--name "$ZONE_NAME" \
	--caller-reference "r53z-pub-${TS}" \
	--hosted-zone-config "Comment=awsbox-public,PrivateZone=false" \
	--query 'HostedZone.Id' --output text)"
ZONE_TOKEN="${ZONE_ID##*/}"
echo "public zone ${ZONE_ID} (${ZONE_NAME})"

CHANGE="/tmp/r53z-change-${TS}.json"
python3 - "$ZONE_NAME" "$ZONE_TOKEN" >"$CHANGE" <<'PY'
import json, sys
zone, zid = sys.argv[1:]
apex = zone if zone.endswith(".") else zone + "."

def rr(name, typ, **extra):
    item = {"Name": f"{name}.{apex}", "Type": typ}
    item.update(extra)
    return {"Action": "UPSERT", "ResourceRecordSet": item}

print(json.dumps({"Changes": [
    rr("target", "A", TTL=60, ResourceRecords=[{"Value": "203.0.113.50"}]),
    rr("api", "A", AliasTarget={
        "HostedZoneId": zid,
        "DNSName": f"target.{apex}",
        "EvaluateTargetHealth": False,
    }),
    rr("www", "CNAME", TTL=60, ResourceRecords=[{"Value": f"api.{apex}"}]),
]}))
PY
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://${CHANGE}" >/dev/null

LISTED="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --output json)"
python3 - "$LISTED" "$ZONE_NAME" <<'PY' || fail "list-resource-record-sets missing A-alias/CNAME/A"
import json, sys
data = json.loads(sys.argv[1])
zone = sys.argv[2].rstrip(".").lower()
want = {
    (f"target.{zone}", "A"),
    (f"api.{zone}", "A"),
    (f"www.{zone}", "CNAME"),
}
found = set()
alias_api = False
for rr in data.get("ResourceRecordSets") or []:
    name = str(rr.get("Name") or "").rstrip(".").lower()
    typ = str(rr.get("Type") or "")
    found.add((name, typ))
    if name == f"api.{zone}" and typ == "A" and rr.get("AliasTarget"):
        alias_api = True
missing = want - found
if missing:
    raise SystemExit(f"missing {missing}")
if not alias_api:
    raise SystemExit("api A is not an alias")
print("ok list-resource-record-sets has target A, api A-alias, www CNAME")
PY

# Wait for resolver API refresh (≤1s cache)
sleep 2
for name in "target.${ZONE_NAME}" "api.${ZONE_NAME}" "www.${ZONE_NAME}"; do
	out="$(resolve_a "$name")"
	echo "$out" | grep -q "203.0.113.50" || fail "dig @127.0.0.1 ${name} expected 203.0.113.50, got: ${out:-empty}"
	echo "ok dig @127.0.0.1 ${name} -> 203.0.113.50"
done

# --- private zone still creatable (resolution covered by r53-private-smoke) ---
PRIV_VPC="$(aws ec2 create-vpc --cidr-block 10.56.0.0/16 --query 'Vpc.VpcId' --output text)"
PRIV_ZONE_ID="$(aws route53 create-hosted-zone \
	--name "priv-${TS}.internal" \
	--caller-reference "r53z-priv-${TS}" \
	--hosted-zone-config "PrivateZone=true,Comment=awsbox" \
	--vpc "VPCRegion=${REGION},VPCId=${PRIV_VPC}" \
	--query 'HostedZone.Id' --output text)"
PRIV_CFG="$(aws route53 get-hosted-zone --id "$PRIV_ZONE_ID" --query 'HostedZone.Config.PrivateZone' --output text)"
[[ "$PRIV_CFG" == "True" || "$PRIV_CFG" == "true" ]] || fail "private zone Config.PrivateZone=${PRIV_CFG}"
echo "ok private zone create ${PRIV_ZONE_ID}"

# --- optional profile local list (endpoint override; profile still supplies keys) ---
if [[ "$PROFILE_CHECK" == "1" ]]; then
	"$ROOT/bin/stackwrangler-profile" write --force >/dev/null
	LIST_OUT="$(AWS_PROFILE=local aws --endpoint-url "$EP" route53 list-hosted-zones \
		--query "length(HostedZones[?Id=='${ZONE_ID}'])" --output text)"
	[[ "$LIST_OUT" == "1" ]] || fail "profile local list-hosted-zones did not include public zone"
	echo "ok profile local list-hosted-zones"
fi

# --- sad: deny ListHostedZones ---
DENY_USER="r53z-deny-${TS}"
aws iam create-user --user-name "$DENY_USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "r53z-deny-${TS}" --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Deny", "Action": "route53:ListHostedZones", "Resource": "*"}]
}' --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$DENY_USER" --policy-arn "$POLICY_ARN"
AK_JSON="$(aws iam create-access-key --user-name "$DENY_USER" --output json)"
DENY_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$AK_JSON")"
DENY_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$AK_JSON")"
set +e
DENY_ERR="$(AWS_ACCESS_KEY_ID="$DENY_KEY" AWS_SECRET_ACCESS_KEY="$DENY_SECRET" \
	command aws --endpoint-url "$EP" --region "$REGION" route53 list-hosted-zones 2>&1)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || fail "route53 list-hosted-zones succeeded for deny user"
echo "$DENY_ERR" | grep -qiE 'AccessDenied|not authorized|ExplicitDenial|Denied' \
	|| fail "deny error missing AccessDenied: ${DENY_ERR}"
echo "ok route53 ListHostedZones denied"

[[ -f "$SLICE/template.yaml" ]] || fail "missing slice template ${SLICE}/template.yaml"
[[ -f "$SLICE/serverless.yml" ]] || fail "missing slice serverless.yml"
echo "ok slice dns present"

echo "OK: route53 public zone + A/alias/CNAME; dig; private create; profile list; ListHostedZones deny"
