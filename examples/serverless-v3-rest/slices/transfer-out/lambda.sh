# Sourced by smokes/transfer/transfer-connector-smoke.sh: deploy the slice handler without the Serverless CLI.
# Needs: aws(), TS, TMP, SLICE, ROLES, FNS from the caller.

LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
SLICE_FN="awsbox-xfer-fn-${TS}"
SLICE_FN_NOPASS="awsbox-xfer-fn-nopass-${TS}"

_slice_wait_active() {
	local s=""
	for _ in $(seq 1 60); do
		s="$(aws lambda get-function --function-name "$1" --query Configuration.State --output text 2>/dev/null || echo Pending)"
		[[ "$s" == Active ]] && return 0
		sleep 2
	done
	echo "FAIL: $1 never Active" >&2
	return 1
}

_slice_fn() { # function-name role-name with-passrole(0/1)
	local actions='"transfer:CreateConnector","transfer:UpdateConnector","transfer:TestConnection","transfer:StartFileTransfer","transfer:ListFileTransferResults"'
	local stmts="{\"Effect\":\"Allow\",\"Action\":[${actions}],\"Resource\":\"*\"}"
	[[ "$3" == 1 ]] && stmts="${stmts},{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"*\"}"
	aws iam create-role --role-name "$2" --assume-role-policy-document "$LAMBDA_TRUST" >/dev/null
	ROLES+=("$2")
	aws iam put-role-policy --role-name "$2" --policy-name inline \
		--policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[${stmts}]}" >/dev/null
	aws lambda create-function --function-name "$1" --runtime nodejs20.x \
		--role "$(aws iam get-role --role-name "$2" --query Role.Arn --output text)" \
		--handler handler.main --zip-file "fileb://${TMP}/slice.zip" --timeout 60 >/dev/null
	FNS+=("$1")
	_slice_wait_active "$1"
}

slice_deploy() {
	python3 - "$SLICE/handler.js" "$TMP/slice.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[1], "handler.js")
PY
	_slice_fn "$SLICE_FN" "awsbox-xfer-fnrole-${TS}" 1
	_slice_fn "$SLICE_FN_NOPASS" "awsbox-xfer-fnrole-nopass-${TS}" 0
}

_slice_call() { # function-name action json
	local payload
	payload="$(python3 -c 'import json,sys; d=json.loads(sys.argv[2]); d["action"]=sys.argv[1]; print(json.dumps(d))' "$2" "$3")"
	aws lambda invoke --function-name "$1" --cli-binary-format raw-in-base64-out \
		--payload "$payload" "$TMP/out.json" >/dev/null
	cat "$TMP/out.json"
}
slice_invoke() { _slice_call "$SLICE_FN" "$@"; }
slice_invoke_nopassrole() { _slice_call "$SLICE_FN_NOPASS" "$@"; }
