#!/usr/bin/env bash
# Happy: create stream → put record → get records → delete stream.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
STREAM="awsbox-kinesis-${TS}"
KEEP="${AWSBOX_KINESIS_KEEP:-0}"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws kinesis delete-stream --stream-name "$STREAM" >/dev/null 2>&1 || true
}
trap cleanup EXIT
aws kinesis create-stream --stream-name "$STREAM" --shard-count 1 >/dev/null
for _ in $(seq 1 60); do
	st="$(aws kinesis describe-stream-summary --stream-name "$STREAM" --query 'StreamDescriptionSummary.StreamStatus' --output text 2>/dev/null \
		|| aws kinesis describe-stream --stream-name "$STREAM" --query 'StreamDescription.StreamStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
[[ "$st" == "ACTIVE" ]] || { echo "FAIL: stream not ACTIVE (${st})" >&2; exit 1; }
DATA_FILE="${TMPDIR:-/tmp}/awsbox-kinesis-data-$$"
printf 'awsbox-%s' "$TS" >"$DATA_FILE"
SEQ="$(aws kinesis put-record --stream-name "$STREAM" --partition-key "pk" --data "fileb://${DATA_FILE}" --query 'SequenceNumber' --output text)"
rm -f "$DATA_FILE"
[[ -n "$SEQ" && "$SEQ" != "None" ]]
SHARD="$(aws kinesis list-shards --stream-name "$STREAM" --query 'Shards[0].ShardId' --output text)"
ITER="$(aws kinesis get-shard-iterator --stream-name "$STREAM" --shard-id "$SHARD" --shard-iterator-type TRIM_HORIZON --query 'ShardIterator' --output text)"
found=0
needle="awsbox-${TS}"
for _ in $(seq 1 20); do
	OUT="$(aws kinesis get-records --shard-iterator "$ITER" --output json)"
	if echo "$OUT" | NEEDLE="$needle" python3 -c '
import json,sys,base64,os
needle=os.environ["NEEDLE"]
d=json.load(sys.stdin)
for r in d.get("Records") or []:
  data=r.get("Data") or ""
  try:
    raw=base64.b64decode(data)
  except Exception:
    raw=data.encode() if isinstance(data,str) else data
  if isinstance(raw, bytes):
    if needle.encode() in raw:
      raise SystemExit(0)
  elif needle in str(raw):
    raise SystemExit(0)
raise SystemExit(1)
'; then
		found=1
		break
	fi
	ITER="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("NextShardIterator") or "")')"
	[[ -n "$ITER" ]] || break
	sleep 1
done
[[ "$found" -eq 1 ]] || { echo "FAIL: record not read back (seq=${SEQ})" >&2; exit 1; }
echo "OK: kinesis put/get (${STREAM})"
