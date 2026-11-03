#!/usr/bin/env bash
# Run day-to-day aws s3 / s3api checks against local SeaweedFS (:8333).
# Does not use --profile / ~/.aws — see smokes/lib/local-emu-env.sh.
# Usage: ./bin/s3-parity.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
S3_EP="${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}"
REGION="${AWSBOX_REGION:-us-east-1}"
PREFIX="awsbox-parity-$(date +%s)"
BUCKET="${PREFIX}-b"
BUCKET2="${PREFIX}-b2"
MP_BUCKET="${PREFIX}-mp"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; aws --endpoint-url "$S3_EP" --region "$REGION" s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true; aws --endpoint-url "$S3_EP" --region "$REGION" s3 rb "s3://${BUCKET2}" --force >/dev/null 2>&1 || true; aws --endpoint-url "$S3_EP" --region "$REGION" s3 rb "s3://${MP_BUCKET}" --force >/dev/null 2>&1 || true' EXIT

AWS=(aws --endpoint-url "$S3_EP" --region "$REGION")
pass=0
fail=0
gap=0
rows=()

note() {
	rows+=("| \`$1\` | $2 | $3 |")
}

run() {
	local id="$1"
	local kind="$2"
	shift 2
	if "$@" >"$WORKDIR/out" 2>"$WORKDIR/err"; then
		note "$id" "pass" ""
		pass=$((pass + 1))
		return 0
	fi
	local err
	err="$(tr '\n' ' ' <"$WORKDIR/err" | head -c 200)"
	if [[ "$kind" == "req" ]]; then
		note "$id" "**FAIL**" "$err"
		fail=$((fail + 1))
		return 1
	fi
	note "$id" "gap" "$err"
	gap=$((gap + 1))
	return 0
}

echo "# S3 parity — endpoint \`$S3_EP\`"
echo
echo "Generated: $(date -Iseconds)  ·  prefix \`$PREFIX\`"
echo
echo "| Check | Result | Detail |"
echo "|-------|--------|--------|"

set +e

run "s3 mb" req "${AWS[@]}" s3 mb "s3://${BUCKET}"
run "s3 ls (root)" req "${AWS[@]}" s3 ls
printf 'hello-parity\n' >"$WORKDIR/upload.txt"
run "s3 cp upload" req "${AWS[@]}" s3 cp "$WORKDIR/upload.txt" "s3://${BUCKET}/hello.txt"
run "s3 ls bucket" req "${AWS[@]}" s3 ls "s3://${BUCKET}/"
run "s3 cp download" req "${AWS[@]}" s3 cp "s3://${BUCKET}/hello.txt" "$WORKDIR/hello.txt"
run "s3 cp copy" req "${AWS[@]}" s3 cp "s3://${BUCKET}/hello.txt" "s3://${BUCKET}/hello-copy.txt"
run "s3 mv" req "${AWS[@]}" s3 mv "s3://${BUCKET}/hello-copy.txt" "s3://${BUCKET}/hello-moved.txt"
run "s3 rm object" req "${AWS[@]}" s3 rm "s3://${BUCKET}/hello-moved.txt"
mkdir -p "$WORKDIR/sync"
echo a >"$WORKDIR/sync/a.txt"
echo b >"$WORKDIR/sync/b.txt"
run "s3 sync up" req "${AWS[@]}" s3 sync "$WORKDIR/sync" "s3://${BUCKET}/sync/"
run "s3 sync down" req "${AWS[@]}" s3 sync "s3://${BUCKET}/sync/" "$WORKDIR/sync-down"
run "s3 presign" opt "${AWS[@]}" s3 presign "s3://${BUCKET}/hello.txt"
run "s3 rb --force" req "${AWS[@]}" s3 rb "s3://${BUCKET}" --force

run "s3api create-bucket" req "${AWS[@]}" s3api create-bucket --bucket "$BUCKET2"
printf 'api-body\n' >"$WORKDIR/api-body.txt"
run "s3api put-object" req "${AWS[@]}" s3api put-object --bucket "$BUCKET2" --key api.txt --body "$WORKDIR/api-body.txt"
run "s3api head-object" req "${AWS[@]}" s3api head-object --bucket "$BUCKET2" --key api.txt
run "s3api get-object" req "${AWS[@]}" s3api get-object --bucket "$BUCKET2" --key api.txt "$WORKDIR/api-out.txt"
run "s3api list-objects-v2" req "${AWS[@]}" s3api list-objects-v2 --bucket "$BUCKET2"
run "s3api delete-object" req "${AWS[@]}" s3api delete-object --bucket "$BUCKET2" --key api.txt
run "s3api head-bucket" req "${AWS[@]}" s3api head-bucket --bucket "$BUCKET2"
run "s3api delete-bucket" req "${AWS[@]}" s3api delete-bucket --bucket "$BUCKET2"

run "s3api create-bucket (multipart)" req "${AWS[@]}" s3api create-bucket --bucket "$MP_BUCKET"
UPLOAD_ID="$("${AWS[@]}" s3api create-multipart-upload --bucket "$MP_BUCKET" --key multi.bin --query UploadId --output text 2>"$WORKDIR/err")"
if [[ -n "${UPLOAD_ID:-}" && "$UPLOAD_ID" != "None" ]]; then
	dd if=/dev/urandom of="$WORKDIR/p1" bs=1024 count=5500 status=none
	dd if=/dev/urandom of="$WORKDIR/p2" bs=1024 count=5500 status=none
	E1="$("${AWS[@]}" s3api upload-part --bucket "$MP_BUCKET" --key multi.bin --part-number 1 --upload-id "$UPLOAD_ID" --body "$WORKDIR/p1" --query ETag --output text 2>"$WORKDIR/err")"
	E2="$("${AWS[@]}" s3api upload-part --bucket "$MP_BUCKET" --key multi.bin --part-number 2 --upload-id "$UPLOAD_ID" --body "$WORKDIR/p2" --query ETag --output text 2>"$WORKDIR/err")"
	E1="${E1//\"/}"
	E2="${E2//\"/}"
	printf '{"Parts":[{"ETag":"%s","PartNumber":1},{"ETag":"%s","PartNumber":2}]}' "$E1" "$E2" >"$WORKDIR/parts.json"
	if "${AWS[@]}" s3api complete-multipart-upload --bucket "$MP_BUCKET" --key multi.bin --upload-id "$UPLOAD_ID" --multipart-upload "file://$WORKDIR/parts.json" >/dev/null 2>"$WORKDIR/err"; then
		note "s3api multipart" "pass" ""
		pass=$((pass + 1))
	else
		note "s3api multipart" "gap" "$(tr '\n' ' ' <"$WORKDIR/err" | head -c 200)"
		gap=$((gap + 1))
		"${AWS[@]}" s3api abort-multipart-upload --bucket "$MP_BUCKET" --key multi.bin --upload-id "$UPLOAD_ID" >/dev/null 2>&1 || true
	fi
else
	note "s3api multipart" "gap" "$(tr '\n' ' ' <"$WORKDIR/err" | head -c 200)"
	gap=$((gap + 1))
fi
run "s3 rb multipart bucket" opt "${AWS[@]}" s3 rb "s3://${MP_BUCKET}" --force

set -e

printf '%s\n' "${rows[@]}"
echo
echo "**Summary:** pass=$pass fail=$fail gap=$gap"
if [[ "$fail" -gt 0 ]]; then
	exit 1
fi
exit 0
