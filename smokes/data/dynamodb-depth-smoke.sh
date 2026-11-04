#!/usr/bin/env bash
# DynamoDB beyond put/get (#296): token table from examples/serverless-v3-rest/slices/ddb
# deployed via CloudFormation, then GSI query, scan filter, conditional writes,
# UpdateItem expressions, TransactWriteItems, TTL expiry and IAM on table/index ARNs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
SLICE="$ROOT/examples/serverless-v3-rest/slices/ddb"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
ADMIN_KEY="$AWS_ACCESS_KEY_ID" ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
TS="$(date +%s)"
STACK="awsbox-ddb-depth-${TS}"
TABLE="awsbox-tokens-${TS}"
INDEX="tokenHash-index"
KEEP="${AWSBOX_DDB_KEEP:-0}"
TMP="$(mktemp -d)"
USERS=() POLICIES=() KEYS=()
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	set +e
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	local i user pol key
	for i in "${!USERS[@]}"; do
		user="${USERS[$i]}" pol="${POLICIES[$i]:-}" key="${KEYS[$i]:-}"
		[[ -n "$key" ]] && aws iam delete-access-key --user-name "$user" --access-key-id "$key" >/dev/null 2>&1
		if [[ -n "$pol" ]]; then
			aws iam detach-user-policy --user-name "$user" --policy-arn "$pol" >/dev/null 2>&1
			aws iam delete-policy --policy-arn "$pol" >/dev/null 2>&1
		fi
		aws iam delete-user --user-name "$user" >/dev/null 2>&1
	done
	aws cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1
	aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Runs a command expecting failure whose output contains $1 (extended regex).
expect_err() {
	local pat="$1" out rc
	shift
	set +e
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "expected error /${pat}/, command succeeded: $*"
	echo "$out" | grep -qE "$pat" || fail "expected /${pat}/, got: $out"
}

jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "== deploy slice (CloudFormation): ${TABLE}"
aws cloudformation deploy \
	--stack-name "$STACK" \
	--template-file "$SLICE/resources.yml" \
	--parameter-overrides "TableName=${TABLE}" \
	--no-fail-on-empty-changeset >/dev/null
for _ in $(seq 1 30); do
	st="$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
[[ "$st" == "ACTIVE" ]] || fail "table not ACTIVE (${st})"

DESC="$(aws dynamodb describe-table --table-name "$TABLE" --output json)"
echo "$DESC" | jq_py "[g['IndexName'] for g in d['Table'].get('GlobalSecondaryIndexes',[])]" | grep -q "$INDEX" \
	|| fail "GSI ${INDEX} missing from describe-table"
TABLE_ARN="$(echo "$DESC" | jq_py "d['Table']['TableArn']")"
INDEX_ARN="${TABLE_ARN}/index/${INDEX}"
TTL_STATUS="$(aws dynamodb describe-time-to-live --table-name "$TABLE" --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)"
[[ "$TTL_STATUS" == "ENABLED" || "$TTL_STATUS" == "ENABLING" ]] || fail "TTL not enabled (${TTL_STATUS})"
TTL_ATTR="$(aws dynamodb describe-time-to-live --table-name "$TABLE" --query 'TimeToLiveDescription.AttributeName' --output text)"
[[ "$TTL_ATTR" == "expiresAt" ]] || fail "TTL attribute ${TTL_ATTR}"
echo "OK: table + GSI + TTL(expiresAt) from CFN"

NOW="$(date +%s)"
FUTURE=$((NOW + 3600))
PAST=$((NOW - 3600))

echo "== conditional PutItem (no overwrite)"
put() { aws dynamodb put-item --table-name "$TABLE" "$@"; }
item() { # pk sk hash uses expiresAt
	printf '{"pk":{"S":"%s"},"sk":{"S":"%s"},"tokenHash":{"S":"%s"},"uses":{"N":"%s"},"expiresAt":{"N":"%s"}}' "$1" "$2" "$3" "$4" "$5"
}
put --item "$(item user#1 token#a hash-a 0 "$FUTURE")" \
	--condition-expression 'attribute_not_exists(pk) AND attribute_not_exists(sk)' >/dev/null
expect_err 'ConditionalCheckFailedException' \
	aws dynamodb put-item --table-name "$TABLE" --item "$(item user#1 token#a hash-other 0 "$FUTURE")" \
	--condition-expression 'attribute_not_exists(pk) AND attribute_not_exists(sk)'
HASH="$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"user#1"},"sk":{"S":"token#a"}}' --query 'Item.tokenHash.S' --output text)"
[[ "$HASH" == "hash-a" ]] || fail "duplicate put overwrote item (${HASH})"
echo "OK: duplicate put -> ConditionalCheckFailedException, item untouched"

echo "== GSI query + scan filter"
put --item "$(item user#1 token#b hash-b 0 "$FUTURE")" >/dev/null
put --item "$(item user#2 token#c hash-c 5 "$FUTURE")" >/dev/null
Q="$(aws dynamodb query --table-name "$TABLE" --index-name "$INDEX" \
	--key-condition-expression 'tokenHash = :h' --expression-attribute-values '{":h":{"S":"hash-b"}}' --output json)"
[[ "$(echo "$Q" | jq_py "d['Count']")" == "1" ]] || fail "GSI query count: $Q"
[[ "$(echo "$Q" | jq_py "d['Items'][0]['sk']['S']")" == "token#b" ]] || fail "GSI query wrong item: $Q"
Q="$(aws dynamodb query --table-name "$TABLE" \
	--key-condition-expression 'pk = :p AND begins_with(sk, :s)' \
	--expression-attribute-values '{":p":{"S":"user#1"},":s":{"S":"token#"}}' --select COUNT --output json)"
[[ "$(echo "$Q" | jq_py "d['Count']")" == "2" ]] || fail "table query count: $Q"
S="$(aws dynamodb scan --table-name "$TABLE" --filter-expression 'uses >= :u' \
	--expression-attribute-values '{":u":{"N":"5"}}' --output json)"
[[ "$(echo "$S" | jq_py "d['Count']")" == "1" ]] || fail "scan filter count: $S"
[[ "$(echo "$S" | jq_py "d['Items'][0]['pk']['S']")" == "user#2" ]] || fail "scan filter wrong item: $S"
echo "OK: GSI query, table query, scan with filter"

echo "== UpdateItem expressions"
KEY='{"pk":{"S":"user#1"},"sk":{"S":"token#a"}}'
UPD="$(aws dynamodb update-item --table-name "$TABLE" --key "$KEY" \
	--update-expression 'SET #u = #u + :one, lastUsed = if_not_exists(lastUsed, :ts) REMOVE tokenHash' \
	--condition-expression '#u < :max' \
	--expression-attribute-names '{"#u":"uses"}' \
	--expression-attribute-values "{\":one\":{\"N\":\"1\"},\":max\":{\"N\":\"2\"},\":ts\":{\"N\":\"${NOW}\"}}" \
	--return-values ALL_NEW --output json)"
[[ "$(echo "$UPD" | jq_py "d['Attributes']['uses']['N']")" == "1" ]] || fail "update uses: $UPD"
[[ "$(echo "$UPD" | jq_py "d['Attributes']['lastUsed']['N']")" == "${NOW}" ]] || fail "update if_not_exists: $UPD"
echo "$UPD" | jq_py "'tokenHash' in d['Attributes']" | grep -q False || fail "REMOVE tokenHash: $UPD"
Q="$(aws dynamodb query --table-name "$TABLE" --index-name "$INDEX" \
	--key-condition-expression 'tokenHash = :h' --expression-attribute-values '{":h":{"S":"hash-a"}}' --select COUNT --output json)"
[[ "$(echo "$Q" | jq_py "d['Count']")" == "0" ]] || fail "item still in GSI after REMOVE of key attr: $Q"
for _ in 1 2; do # uses 1 -> 2 passes (<2 is false at 2)
	aws dynamodb update-item --table-name "$TABLE" --key "$KEY" \
		--update-expression 'SET #u = #u + :one' --condition-expression '#u < :max' \
		--expression-attribute-names '{"#u":"uses"}' \
		--expression-attribute-values '{":one":{"N":"1"},":max":{"N":"2"}}' >/dev/null 2>&1 || break
done
expect_err 'ConditionalCheckFailedException' \
	aws dynamodb update-item --table-name "$TABLE" --key "$KEY" \
	--update-expression 'SET #u = #u + :one' --condition-expression '#u < :max' \
	--expression-attribute-names '{"#u":"uses"}' \
	--expression-attribute-values '{":one":{"N":"1"},":max":{"N":"2"}}'
echo "OK: UpdateItem SET/if_not_exists/REMOVE, failed condition -> ConditionalCheckFailedException, GSI follows key removal"

echo "== TransactWriteItems"
cat >"$TMP/tx-ok.json" <<EOF
[
 {"Put":{"TableName":"$TABLE","Item":$(item user#3 token#d hash-d 0 "$FUTURE"),"ConditionExpression":"attribute_not_exists(pk)"}},
 {"Update":{"TableName":"$TABLE","Key":{"pk":{"S":"user#2"},"sk":{"S":"token#c"}},"UpdateExpression":"SET uses = uses + :one","ExpressionAttributeValues":{":one":{"N":"1"}}}}
]
EOF
aws dynamodb transact-write-items --transact-items "file://$TMP/tx-ok.json" >/dev/null
[[ "$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"user#2"},"sk":{"S":"token#c"}}' --query 'Item.uses.N' --output text)" == "6" ]] \
	|| fail "transaction update not applied"
cat >"$TMP/tx-bad.json" <<EOF
[
 {"Put":{"TableName":"$TABLE","Item":$(item user#4 token#e hash-e 0 "$FUTURE")}},
 {"Put":{"TableName":"$TABLE","Item":$(item user#3 token#d hash-x 0 "$FUTURE"),"ConditionExpression":"attribute_not_exists(pk)"}}
]
EOF
expect_err 'TransactionCanceledException.*ConditionalCheckFailed' \
	aws dynamodb transact-write-items --transact-items "file://$TMP/tx-bad.json"
GOT="$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"user#4"},"sk":{"S":"token#e"}}' --output json)"
[[ "$GOT" != *'"Item"'* ]] || fail "cancelled transaction left a partial write: $GOT"
echo "OK: transaction commits atomically; failed condition cancels all"

echo "== TTL expiry"
put --item "$(item ttl#1 expired hash-ttl-1 0 "$PAST")" >/dev/null
put --item "$(item ttl#1 live hash-ttl-2 0 "$FUTURE")" >/dev/null
EXPIRED_HOOK="${AWSBOX_DDB_EXPIRE_URL:-$EP/_aws/dynamodb/expired}"
gone=0
for attempt in $(seq 1 3); do
	# LocalEmu sweeps hourly; this hook runs the sweep now (not an AWS API).
	curl -fsS -X DELETE "$EXPIRED_HOOK" >/dev/null 2>&1 || true
	GOT="$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"ttl#1"},"sk":{"S":"expired"}}' --output json)"
	if [[ "$GOT" != *'"Item"'* ]]; then gone=1; break; fi
	sleep 2
done
[[ "$gone" == "1" ]] || fail "expired item still present after TTL sweep (gap: no TTL deletion)"
GOT="$(aws dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"ttl#1"},"sk":{"S":"live"}}' --output json)"
[[ "$GOT" == *'"Item"'* ]] || fail "unexpired item was removed by TTL sweep"
Q="$(aws dynamodb query --table-name "$TABLE" --index-name "$INDEX" \
	--key-condition-expression 'tokenHash = :h' --expression-attribute-values '{":h":{"S":"hash-ttl-1"}}' --select COUNT --output json)"
[[ "$(echo "$Q" | jq_py "d['Count']")" == "0" ]] || fail "expired item still in GSI"
echo "OK: expired item removed (table + GSI), live item kept"

echo "== IAM on table and index ARNs"
mkuser() { # name policy-json -> sets U_KEY U_SECRET
	local name="$1" doc="$2" pol_arn keys
	printf '%s' "$doc" >"$TMP/${name}.json"
	aws iam create-user --user-name "$name" >/dev/null
	USERS+=("$name")
	pol_arn="$(aws iam create-policy --policy-name "${name}-p" --policy-document "file://$TMP/${name}.json" --query 'Policy.Arn' --output text)"
	POLICIES+=("$pol_arn")
	aws iam attach-user-policy --user-name "$name" --policy-arn "$pol_arn" >/dev/null
	keys="$(aws iam create-access-key --user-name "$name" --output json)"
	U_KEY="$(echo "$keys" | jq_py "d['AccessKey']['AccessKeyId']")"
	U_SECRET="$(echo "$keys" | jq_py "d['AccessKey']['SecretAccessKey']")"
	KEYS+=("$U_KEY")
}
as() { AWS_ACCESS_KEY_ID="$U_KEY" AWS_SECRET_ACCESS_KEY="$U_SECRET" aws "$@"; }
QARGS=(--key-condition-expression 'tokenHash = :h' --expression-attribute-values '{":h":{"S":"hash-b"}}')
TQARGS=(--key-condition-expression 'pk = :p' --expression-attribute-values '{":p":{"S":"user#1"}}')

# Index-only reader: Query on the GSI ARN, nothing on the table.
mkuser "awsbox-ddb-idx-${TS}" "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:Query\",\"Resource\":\"${INDEX_ARN}\"}]}"
sleep 2
as dynamodb query --table-name "$TABLE" --index-name "$INDEX" "${QARGS[@]}" --select COUNT >/dev/null \
	|| fail "index-only user cannot Query the GSI"
expect_err 'AccessDenied|not authorized|ExplicitDeny|implicit' \
	as dynamodb query --table-name "$TABLE" "${TQARGS[@]}"
expect_err 'AccessDenied|not authorized|ExplicitDeny|implicit' \
	as dynamodb put-item --table-name "$TABLE" --item "$(item user#9 token#z hash-z 0 "$FUTURE")"
echo "OK: Allow on index ARN -> GSI Query ok, base-table Query + PutItem denied"

# Table-only reader: ARN without /index/* must not cover the GSI.
mkuser "awsbox-ddb-tbl-${TS}" "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"dynamodb:Query\",\"dynamodb:GetItem\"],\"Resource\":\"${TABLE_ARN}\"}]}"
sleep 2
as dynamodb query --table-name "$TABLE" "${TQARGS[@]}" --select COUNT >/dev/null \
	|| fail "table-only user cannot Query the table"
expect_err 'AccessDenied|not authorized|ExplicitDeny|implicit' \
	as dynamodb query --table-name "$TABLE" --index-name "$INDEX" "${QARGS[@]}"
echo "OK: Allow on table ARN only -> table Query ok, GSI Query denied"

# Deny on the index only.
mkuser "awsbox-ddb-deny-${TS}" "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:*\",\"Resource\":\"*\"},{\"Effect\":\"Deny\",\"Action\":\"dynamodb:Query\",\"Resource\":\"${INDEX_ARN}\"}]}"
sleep 2
as dynamodb query --table-name "$TABLE" "${TQARGS[@]}" --select COUNT >/dev/null \
	|| fail "deny-index user cannot Query the table"
expect_err 'AccessDenied|not authorized|ExplicitDeny' \
	as dynamodb query --table-name "$TABLE" --index-name "$INDEX" "${QARGS[@]}"
echo "OK: explicit Deny on index ARN -> GSI Query denied, table Query ok"

echo "OK: dynamodb depth (${TABLE})"
