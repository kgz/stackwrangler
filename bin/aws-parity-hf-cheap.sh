#!/usr/bin/env bash
# Cheap real-AWS parity for high-focus tickets that are free-tier / cents.
# Local: existing ticket smokes. Real: short-lived create → assert → delete.
#
# Covered (real): #296 DDB depth · #297 EventBridge schedule · #190 REST Deny→403 ·
#                 #294 API keys + usage plan · #230 S3 gateway VPCE create/delete.
# Skipped (cost / domain): see docs/aws-parity-hf-cheap.md
#
# Cost: free-tier / noise if teardown OK. No KMS CMK, no hosted zones, no Transfer,
# no WAF WebACL, no NAT/EIP. Gateway S3 VPCE is $0.
#
# Usage: ./bin/aws-parity-hf-cheap.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
#      AWSBOX_PARITY_REGION (default ap-southeast-2)
#      AWSBOX_PARITY_SKIP_SCHEDULE=1  # skip #297 real wait (~3–4 min)
#      AWSBOX_SCHEDULE_WINDOW / AWSBOX_SCHEDULE_QUIET (real schedule windows)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

TS="$(date +%s)"
KEEP="${AWSBOX_PARITY_KEEP:-0}"
REAL_REGION="${AWSBOX_PARITY_REGION:-ap-southeast-2}"
FAIL=0
CLEANUP_CMDS=()
WORK="$(mktemp -d)"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

on_cleanup() { CLEANUP_CMDS+=("$*"); }

run_cleanup() {
	local i
	if [[ "$KEEP" != "1" ]]; then
		for ((i = ${#CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
			# shellcheck disable=SC2086
			eval "${CLEANUP_CMDS[i]}" >/dev/null 2>&1 || true
		done
	fi
	rm -rf "$WORK"
}
trap run_cleanup EXIT

# --- Local (ticket smokes) ---
if [[ "${AWSBOX_PARITY_SKIP_LOCAL:-0}" != "1" ]]; then
	echo "======== LOCAL ========"
	for s in \
		dynamodb-depth-smoke \
		events-schedule-smoke \
		apigw-rest-smoke \
		apigw-usage-plan-smoke \
		vpc-egress-smoke
	do
		echo "---- local ${s} ----"
		if ! "$ROOT/bin/${s}.sh"; then
			fail "local ${s}"
		else
			pass "local ${s}"
		fi
	done
fi

# --- Real AWS ---
if [[ "${AWSBOX_PARITY_SKIP_REAL:-0}" != "1" ]]; then
	echo "======== REAL (${REAL_REGION}) ========"
	echo "NOTE: creates short-lived resources; teardown on EXIT unless AWSBOX_PARITY_KEEP=1"
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
	unset AWS_PROFILE AWS_DEFAULT_PROFILE
	export AWS_DEFAULT_REGION="$REAL_REGION"
	aws_r() { command aws --region "$REAL_REGION" "$@"; }
	ACCOUNT="$(aws_r sts get-caller-identity --query Account --output text)"
	pass "caller account=${ACCOUNT} region=${REAL_REGION}"

	# Shared Lambda execution role (logs only).
	ROLE="awsbox-parity-hf-lambda-${TS}"
	TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
	aws_r iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
	on_cleanup "aws_r iam delete-role --role-name '$ROLE'"
	aws_r iam attach-role-policy --role-name "$ROLE" \
		--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
	on_cleanup "aws_r iam detach-role-policy --role-name '$ROLE' --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
	ROLE_ARN="$(aws_r iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
	# IAM role propagation
	sleep 8

	zip_js() {
		# zip_js <src.js> <out.zip>
		python3 - "$1" "$2" <<'PY'
import sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(src, "index.js")
PY
	}

	wait_lambda() {
		local fn="$1" st=""
		for _ in $(seq 1 60); do
			st="$(aws_r lambda get-function --function-name "$fn" --query Configuration.State --output text 2>/dev/null || echo Pending)"
			[[ "$st" == "Active" ]] && return 0
			sleep 2
		done
		fail "lambda ${fn} never Active (${st})"
		return 1
	}

	# AWSBOX_PARITY_SCHEDULE_ONLY=1 → skip everything except #297 (faster retest).
	ONLY_SCHED="${AWSBOX_PARITY_SCHEDULE_ONLY:-0}"

	# ========== #296 DynamoDB depth ==========
	if [[ "$ONLY_SCHED" == "1" ]]; then
		echo "---- real #296 SKIPPED (AWSBOX_PARITY_SCHEDULE_ONLY=1) ----"
	else
	echo "---- real #296 dynamodb depth ----"
	TABLE="awsbox-parity-hf-ddb-${TS}"
	STACK="awsbox-parity-hf-ddb-${TS}"
	INDEX="tokenHash-index"
	aws_r cloudformation deploy \
		--stack-name "$STACK" \
		--template-file "$ROOT/examples/serverless-v3-rest/slices/ddb/resources.yml" \
		--parameter-overrides "TableName=${TABLE}" \
		--no-fail-on-empty-changeset >/dev/null
	on_cleanup "aws_r cloudformation delete-stack --stack-name '$STACK'"
	on_cleanup "aws_r dynamodb delete-table --table-name '$TABLE'"
	tbl_st=""
	for _ in $(seq 1 60); do
		tbl_st="$(aws_r dynamodb describe-table --table-name "$TABLE" --query Table.TableStatus --output text 2>/dev/null || true)"
		[[ "$tbl_st" == "ACTIVE" ]] && break
		sleep 2
	done
	[[ "$tbl_st" == "ACTIVE" ]] && pass "real ddb table ACTIVE" || fail "real ddb table status=${tbl_st}"
	aws_r dynamodb describe-table --table-name "$TABLE" --query "Table.GlobalSecondaryIndexes[?IndexName=='${INDEX}'].IndexName" --output text \
		| grep -qx "$INDEX" && pass "real ddb GSI ${INDEX}" || fail "real ddb GSI missing"
	TTL_ST="$(aws_r dynamodb describe-time-to-live --table-name "$TABLE" --query TimeToLiveDescription.TimeToLiveStatus --output text)"
	[[ "$TTL_ST" == "ENABLED" || "$TTL_ST" == "ENABLING" ]] && pass "real ddb TTL ${TTL_ST}" || fail "real ddb TTL ${TTL_ST}"

	FUTURE=$(( $(date +%s) + 3600 ))
	item() {
		printf '{"pk":{"S":"%s"},"sk":{"S":"%s"},"tokenHash":{"S":"%s"},"uses":{"N":"%s"},"expiresAt":{"N":"%s"}}' "$1" "$2" "$3" "$4" "$5"
	}
	aws_r dynamodb put-item --table-name "$TABLE" --item "$(item user#1 token#a hash-a 0 "$FUTURE")" \
		--condition-expression 'attribute_not_exists(pk) AND attribute_not_exists(sk)' >/dev/null
	set +e
	dup_out="$(aws_r dynamodb put-item --table-name "$TABLE" --item "$(item user#1 token#a hash-x 0 "$FUTURE")" \
		--condition-expression 'attribute_not_exists(pk) AND attribute_not_exists(sk)' 2>&1)"
	dup_rc=$?
	set -e
	if [[ "$dup_rc" -ne 0 ]] && echo "$dup_out" | grep -q ConditionalCheckFailedException; then
		pass "real ddb conditional put deny"
	else
		fail "real ddb conditional put: rc=${dup_rc} ${dup_out}"
	fi
	aws_r dynamodb put-item --table-name "$TABLE" --item "$(item user#1 token#b hash-b 0 "$FUTURE")" >/dev/null
	QCNT="$(aws_r dynamodb query --table-name "$TABLE" --index-name "$INDEX" \
		--key-condition-expression 'tokenHash = :h' --expression-attribute-values '{":h":{"S":"hash-b"}}' \
		--select COUNT --query Count --output text)"
	[[ "$QCNT" == "1" ]] && pass "real ddb GSI query" || fail "real ddb GSI query count=${QCNT}"
	# TTL item expiry is ~48h on real AWS — not asserted here (documented gap).

	# ========== #190 REST Deny → 403 ==========
	echo "---- real #190 REST authorizer Deny → 403 ----"
	AUTHZ_SLICE="$ROOT/examples/serverless-v3-rest/slices/apigw-authz"
	zip_js "$AUTHZ_SLICE/handler.js" "$WORK/handler.zip"
	zip_js "$AUTHZ_SLICE/authorizer.js" "$WORK/authorizer.zip"
	FN_H="awsbox-parity-hf-rest-h-${TS}"
	FN_A="awsbox-parity-hf-rest-a-${TS}"
	aws_r lambda create-function --function-name "$FN_H" --runtime nodejs20.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${WORK}/handler.zip" --timeout 10 >/dev/null
	on_cleanup "aws_r lambda delete-function --function-name '$FN_H'"
	aws_r lambda create-function --function-name "$FN_A" --runtime nodejs20.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${WORK}/authorizer.zip" --timeout 10 >/dev/null
	on_cleanup "aws_r lambda delete-function --function-name '$FN_A'"
	wait_lambda "$FN_H"
	wait_lambda "$FN_A"
	HANDLER_URI="arn:aws:apigateway:${REAL_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REAL_REGION}:${ACCOUNT}:function:${FN_H}/invocations"
	AUTHORIZER_URI="arn:aws:apigateway:${REAL_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REAL_REGION}:${ACCOUNT}:function:${FN_A}/invocations"
	AUTHORIZER_URI="$AUTHORIZER_URI" HANDLER_URI="$HANDLER_URI" python3 -c \
		'import os,sys; t=open(sys.argv[1]).read(); print(t.replace("${AUTHORIZER_URI}", os.environ["AUTHORIZER_URI"]).replace("${HANDLER_URI}", os.environ["HANDLER_URI"]))' \
		"$AUTHZ_SLICE/openapi.template.json" >"$WORK/openapi-rest.json"
	API_REST="$(aws_r apigateway import-rest-api --body "fileb://${WORK}/openapi-rest.json" --query id --output text)"
	on_cleanup "aws_r apigateway delete-rest-api --rest-api-id '$API_REST'"
	for fn in "$FN_H" "$FN_A"; do
		aws_r lambda add-permission --function-name "$fn" --statement-id "apigw-rest-${TS}" \
			--action lambda:InvokeFunction --principal apigateway.amazonaws.com \
			--source-arn "arn:aws:execute-api:${REAL_REGION}:${ACCOUNT}:${API_REST}/*" >/dev/null
	done
	aws_r apigateway create-deployment --rest-api-id "$API_REST" --stage-name parity >/dev/null
	BASE_REST="https://${API_REST}.execute-api.${REAL_REGION}.amazonaws.com/parity"
	# Stage propagation
	sleep 5
	req() {
		local code bodyf="$WORK/http-body"
		code="$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 30 "$@")"
		echo "$code"
	}
	code="$(req "${BASE_REST}/v1/items")"
	[[ "$code" == "401" ]] && pass "real rest no token → 401" || fail "real rest no token → ${code} $(cat "$WORK/http-body")"
	code="$(req -H 'Authorization: Bearer bad' "${BASE_REST}/v1/items")"
	body="$(cat "$WORK/http-body")"
	if [[ "$code" == "403" ]] && echo "$body" | grep -qi 'not authorized'; then
		pass "real rest Deny token → 403"
	else
		fail "real rest Deny token → ${code} ${body}"
	fi
	code="$(req -H 'Authorization: Bearer good' "${BASE_REST}/v1/items")"
	[[ "$code" == "200" ]] && pass "real rest Allow token → 200" || fail "real rest Allow → ${code} $(cat "$WORK/http-body")"
	# Custom domain / ACM left to skipped gaps (#74 / #56).

	# ========== #294 API keys + usage plan ==========
	echo "---- real #294 API keys + usage plan ----"
	KEYS_SLICE="$ROOT/examples/serverless-v3-rest/slices/api-keys"
	zip_js "$KEYS_SLICE/handler.js" "$WORK/keys-handler.zip"
	FN_K="awsbox-parity-hf-keys-h-${TS}"
	aws_r lambda create-function --function-name "$FN_K" --runtime nodejs20.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${WORK}/keys-handler.zip" --timeout 10 >/dev/null
	on_cleanup "aws_r lambda delete-function --function-name '$FN_K'"
	wait_lambda "$FN_K"
	HANDLER_URI="arn:aws:apigateway:${REAL_REGION}:lambda:path/2015-03-31/functions/arn:aws:lambda:${REAL_REGION}:${ACCOUNT}:function:${FN_K}/invocations"
	HANDLER_URI="$HANDLER_URI" python3 -c \
		'import os,sys; print(open(sys.argv[1]).read().replace("${HANDLER_URI}", os.environ["HANDLER_URI"]))' \
		"$KEYS_SLICE/openapi.template.json" >"$WORK/openapi-keys.json"
	API_KEYS="$(aws_r apigateway import-rest-api --body "fileb://${WORK}/openapi-keys.json" --query id --output text)"
	on_cleanup "aws_r apigateway delete-rest-api --rest-api-id '$API_KEYS'"
	aws_r lambda add-permission --function-name "$FN_K" --statement-id "apigw-keys-${TS}" \
		--action lambda:InvokeFunction --principal apigateway.amazonaws.com \
		--source-arn "arn:aws:execute-api:${REAL_REGION}:${ACCOUNT}:${API_KEYS}/*" >/dev/null
	aws_r apigateway update-rest-api --rest-api-id "$API_KEYS" \
		--patch-operations op=replace,path=/apiKeySource,value=HEADER >/dev/null
	# Mark /v1/items as requiring an API key (OpenAPI security alone is not always enough after import).
	RES_ITEMS="$(aws_r apigateway get-resources --rest-api-id "$API_KEYS" \
		--query "items[?path=='/v1/items'].id" --output text)"
	aws_r apigateway update-method --rest-api-id "$API_KEYS" --resource-id "$RES_ITEMS" --http-method GET \
		--patch-operations op=replace,path=/apiKeyRequired,value=true >/dev/null
	REQ_KEY="$(aws_r apigateway get-method --rest-api-id "$API_KEYS" --resource-id "$RES_ITEMS" --http-method GET \
		--query apiKeyRequired --output text)"
	[[ "$REQ_KEY" == "True" || "$REQ_KEY" == "true" ]] && pass "real keys method apiKeyRequired" \
		|| fail "real keys method apiKeyRequired=${REQ_KEY}"
	aws_r apigateway create-deployment --rest-api-id "$API_KEYS" --stage-name parity >/dev/null
	PLAN="$(aws_r apigateway create-usage-plan --name "awsbox-parity-hf-plan-${TS}" \
		--api-stages "apiId=${API_KEYS},stage=parity" \
		--throttle rateLimit=50,burstLimit=100 --query id --output text)"
	on_cleanup "aws_r apigateway delete-usage-plan --usage-plan-id '$PLAN'"
	KEY_JSON="$(aws_r apigateway create-api-key --name "awsbox-parity-hf-key-${TS}" --enabled --query '{id:id,value:value}' --output json)"
	KID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$KEY_JSON")"
	KVAL="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' <<<"$KEY_JSON")"
	on_cleanup "aws_r apigateway delete-api-key --api-key '$KID'"
	aws_r apigateway create-usage-plan-key --usage-plan-id "$PLAN" --key-id "$KID" --key-type API_KEY >/dev/null
	# Plan/key binding is eventual; redeploy so the stage picks up apiKeyRequired + plan.
	aws_r apigateway create-deployment --rest-api-id "$API_KEYS" --stage-name parity >/dev/null
	BASE_KEYS="https://${API_KEYS}.execute-api.${REAL_REGION}.amazonaws.com/parity"
	code=""
	for _ in $(seq 1 30); do
		code="$(req -H "x-api-key: ${KVAL}" "${BASE_KEYS}/v1/items")"
		[[ "$code" == "200" ]] && break
		sleep 2
	done
	code_open="$(req "${BASE_KEYS}/public/ping")"
	[[ "$code_open" == "200" ]] && pass "real keys open route no key → 200" || fail "real keys open → ${code_open}"
	code_miss="$(req "${BASE_KEYS}/v1/items")"
	[[ "$code_miss" == "403" ]] && pass "real keys missing key → 403" || fail "real keys missing → ${code_miss} $(cat "$WORK/http-body")"
	[[ "$code" == "200" ]] && pass "real keys valid key → 200" || fail "real keys valid → ${code} $(cat "$WORK/http-body")"
	aws_r apigateway update-api-key --api-key "$KID" --patch-operations op=replace,path=/enabled,value=false >/dev/null
	code_dis=""
	for _ in $(seq 1 15); do
		code_dis="$(req -H "x-api-key: ${KVAL}" "${BASE_KEYS}/v1/items")"
		[[ "$code_dis" == "403" ]] && break
		sleep 2
	done
	[[ "$code_dis" == "403" ]] && pass "real keys disabled key → 403" || fail "real keys disabled → ${code_dis}"
	# Throttle/quota burst and Lambda mint IAM are covered locally; skipped on real (flaky / extra IAM).

	# ========== #230 S3 gateway VPCE (control plane only) ==========
	echo "---- real #230 S3 gateway VPC endpoint (create/delete only) ----"
	VPC_ID="$(aws_r ec2 create-vpc --cidr-block 10.249.0.0/16 --query Vpc.VpcId --output text)"
	on_cleanup "aws_r ec2 delete-vpc --vpc-id '$VPC_ID'"
	aws_r ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
	aws_r ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
	RTB="$(aws_r ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
		--query 'RouteTables[0].RouteTableId' --output text)"
	VPCE="$(aws_r ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --service-name "com.amazonaws.${REAL_REGION}.s3" \
		--vpc-endpoint-type Gateway --route-table-ids "$RTB" --query VpcEndpoint.VpcEndpointId --output text)"
	on_cleanup "aws_r ec2 delete-vpc-endpoints --vpc-endpoint-ids '$VPCE'"
	ST="$(aws_r ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE" --query 'VpcEndpoints[0].State' --output text)"
	[[ "$ST" == "available" || "$ST" == "pending" ]] && pass "real s3 gateway vpce ${VPCE} (${ST})" \
		|| fail "real s3 gateway vpce state=${ST}"
	# Full private-Lambda egress / prefix-list enforcement stays local (vpc-egress-smoke).
	fi # ONLY_SCHED else (296/190/294/230)

	# ========== #297 EventBridge schedule → Lambda ==========
	if [[ "${AWSBOX_PARITY_SKIP_SCHEDULE:-0}" == "1" ]]; then
		echo "---- real #297 schedule SKIPPED (AWSBOX_PARITY_SKIP_SCHEDULE=1) ----"
	else
		echo "---- real #297 EventBridge schedule → Lambda ----"
		WINDOW="${AWSBOX_SCHEDULE_WINDOW:-300}"
		QUIET="${AWSBOX_SCHEDULE_QUIET:-90}"
		SCHED_SLICE="$ROOT/examples/serverless-v3-rest/slices/schedule"
		CODE_BUCKET="awsbox-parity-hf-sched-code-${TS}"
		FN_S="awsbox-parity-hf-sched-${TS}"
		RULE_S="awsbox-parity-hf-sched-rule-${TS}"
		STACK_S="awsbox-parity-hf-sched-${TS}"
		# Real Node runtimes do not ship @aws-sdk/*; parity only needs the tick log.
		printf '%s\n' 'exports.handler = async () => { console.log("sweep-tick"); return { ok: true }; };' \
			>"$WORK/sched-index.js"
		python3 - "$WORK/sched-index.js" "$WORK/sched.zip" <<'PY'
import sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(src, "index.js")
PY
		aws_r s3 mb "s3://${CODE_BUCKET}" >/dev/null
		on_cleanup "aws_r s3 rb s3://${CODE_BUCKET} --force"
		aws_r s3 cp "$WORK/sched.zip" "s3://${CODE_BUCKET}/function.zip" >/dev/null
		aws_r cloudformation deploy \
			--stack-name "$STACK_S" \
			--template-file "$SCHED_SLICE/template.yaml" \
			--capabilities CAPABILITY_NAMED_IAM \
			--no-fail-on-empty-changeset \
			--parameter-overrides \
			"FunctionName=${FN_S}" "RuleName=${RULE_S}" "RuleState=ENABLED" "GrantInvoke=true" \
			"ScheduleExpression=rate(1 minute)" \
			"CodeBucket=${CODE_BUCKET}" "CodeKey=function.zip" >/dev/null
		on_cleanup "aws_r cloudformation delete-stack --stack-name '$STACK_S'"
		wait_lambda "$FN_S"
		EXPR="$(aws_r events describe-rule --name "$RULE_S" --query ScheduleExpression --output text)"
		STATE="$(aws_r events describe-rule --name "$RULE_S" --query State --output text)"
		[[ "$EXPR" == "rate(1 minute)" && "$STATE" == "ENABLED" ]] && pass "real schedule expression (${STATE})" \
			|| fail "real schedule expr=${EXPR} state=${STATE}"
		TGT="$(aws_r events list-targets-by-rule --rule "$RULE_S" --query 'Targets[0].Arn' --output text)"
		echo "$TGT" | grep -q ":function:${FN_S}$" && pass "real schedule target" || fail "real schedule target=${TGT}"
		METRIC_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		# Smoke the zip before waiting on the schedule (avoids a long false negative).
		inv_meta="$(aws_r lambda invoke --function-name "$FN_S" --cli-binary-format raw-in-base64-out \
			--payload '{}' "$WORK/sched-inv.json" --output json)"
		if echo "$inv_meta" | grep -qi FunctionError; then
			fail "real schedule manual invoke: ${inv_meta} $(cat "$WORK/sched-inv.json")"
		elif python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); raise SystemExit(0 if d.get("ok") is True else 1)' \
			"$WORK/sched-inv.json"; then
			pass "real schedule manual invoke"
		else
			fail "real schedule manual invoke payload: $(cat "$WORK/sched-inv.json")"
		fi
		count_inv() {
			aws_r cloudwatch get-metric-statistics \
				--namespace AWS/Lambda \
				--metric-name Invocations \
				--dimensions "Name=FunctionName,Value=${FN_S}" \
				--start-time "$METRIC_START" \
				--end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				--period 60 \
				--statistics Sum \
				--output json \
				| python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(sum(p.get("Sum",0) for p in d.get("Datapoints") or [])))'
		}
		echo "waiting up to ${WINDOW}s for Lambda Invocations >= 3 (1 manual + >=2 scheduled)…"
		n=0
		deadline=$((SECONDS + WINDOW))
		while (( SECONDS < deadline )); do
			n="$(count_inv)"
			[[ "$n" -ge 3 ]] && break
			sleep 10
		done
		if [[ "$n" -ge 1 ]]; then sched_n=$((n - 1)); else sched_n=0; fi
		[[ "$sched_n" -ge 2 ]] && pass "real schedule invocations≈${sched_n} (metric total=${n})" \
			|| fail "real schedule invocations≈${sched_n} metric total=${n} (want scheduled >=2)"
		aws_r events disable-rule --name "$RULE_S" >/dev/null
		# One rate(1 minute) tick may already be in flight when we disable.
		DRAIN="${AWSBOX_SCHEDULE_DRAIN:-75}"
		echo "disabled; draining in-flight ~${DRAIN}s before quiet baseline…"
		sleep "$DRAIN"
		baseline="$(count_inv)"
		echo "quiet baseline metric=${baseline}; watching ${QUIET}s…"
		sleep "$QUIET"
		after="$(count_inv)"
		if [[ "$after" -le "$baseline" ]]; then
			pass "real schedule quiet after disable (${after}<=${baseline})"
		else
			fail "real schedule still firing after disable (${after}>${baseline})"
		fi
	fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
	echo "OK: aws-parity-hf-cheap complete (ts=${TS})"
	exit 0
fi
echo "FAIL: aws-parity-hf-cheap had ${FAIL} failure(s) (ts=${TS})" >&2
exit 1
