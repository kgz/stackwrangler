#!/usr/bin/env bash
# Transfer Family outbound SFTP connector (#295): an S3 object is sent to a remote SFTP host.
# Slice: examples/serverless-v3-rest/slices/transfer-out (Lambda creates the per-tenant connector
# at runtime, then calls StartFileTransfer). SFTP target = the compose `sftp` container.
#
# Happy: Lambda onboards tenant connector (CreateConnector -> TestConnection host key ->
#        UpdateConnector TrustedHostKeys) and sends s3://bucket/key; file lands on the SFTP host;
#        transfer events appear in /aws/transfer/<connector-id>.
# Sad/authz: access role without s3:GetObject, without GetSecretValue, without kms:Decrypt on the
#        secret's CMK, with a trust policy scoped to another account's connectors -> FAILED, no file.
# Sad/other: wrong host key; Lambda role without iam:PassRole -> CreateConnector denied.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
SFTP_USER="${AWSBOX_SFTP_USER:-awsbox}"
SFTP_PASS="${AWSBOX_SFTP_PASS:-awsboxpass}"
SFTP_URL="${AWSBOX_SFTP_CONNECTOR_URL:-sftp://sftp:22}"
TS="$(date +%s)"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"
BUCKET="awsbox-xfer-out-${TS}"
OBJ_KEY="outbound/invoice-${TS}.txt"
SLICE="$ROOT/examples/serverless-v3-rest/slices/transfer-out"
TMP="$(mktemp -d)"
FAILS=0
CONNECTORS=()
ROLES=()
FNS=()
SECRET_ID="awsbox/transfer-out/${TS}/sftp"
LOG_ROLE="awsbox-xfer-log-${TS}"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	for c in "${CONNECTORS[@]:-}"; do
		[[ -n "$c" ]] && aws transfer delete-connector --connector-id "$c" >/dev/null 2>&1 || true
		[[ -n "$c" ]] && aws logs delete-log-group --log-group-name "/aws/transfer/$c" >/dev/null 2>&1 || true
	done
	for f in "${FNS[@]:-}"; do
		[[ -n "$f" ]] && aws lambda delete-function --function-name "$f" >/dev/null 2>&1 || true
	done
	for r in "${ROLES[@]:-}"; do
		[[ -n "$r" ]] || continue
		for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
			aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
		done
		aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	aws secretsmanager delete-secret --secret-id "$SECRET_ID" --force-delete-without-recovery >/dev/null 2>&1 || true
	[[ -n "${KEY_ID:-}" ]] && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	sftp_sh "rm -f /home/awsbox/upload/*-${TS}*" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check() { # label status(0 = pass)
	if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}

cd "$ROOT"
docker compose up -d sftp >/dev/null
sftp_sh() { docker compose exec -T sftp sh -c "$1"; }
for _ in $(seq 1 30); do
	sftp_sh true 2>/dev/null && break
	sleep 1
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CONNECTOR_ARN_GLOB="arn:aws:transfer:${REGION}:${ACCOUNT}:connector/*"
trust() { # source-arn-glob source-account
	cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"transfer.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$2"},"ArnLike":{"aws:SourceArn":"$1"}}}]}
EOF
}

aws s3 mb "s3://${BUCKET}" >/dev/null
echo "awsbox transfer out ${TS}" >"$TMP/payload.txt"
aws s3 cp "$TMP/payload.txt" "s3://${BUCKET}/${OBJ_KEY}" >/dev/null

KEY_ID="$(aws kms create-key --description "awsbox transfer-out ${TS}" --query KeyMetadata.KeyId --output text)"
KEY_ARN="$(aws kms describe-key --key-id "$KEY_ID" --query KeyMetadata.Arn --output text)"
aws secretsmanager create-secret --name "$SECRET_ID" --kms-key-id "$KEY_ID" \
	--secret-string "{\"Username\":\"${SFTP_USER}\",\"Password\":\"${SFTP_PASS}\"}" >/dev/null
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_ID" --query ARN --output text)"

mk_role() { # name trust-doc statements-json(array)
	aws iam create-role --role-name "$1" --assume-role-policy-document "$2" >/dev/null
	ROLES+=("$1")
	if [[ -n "${3:-}" ]]; then
		aws iam put-role-policy --role-name "$1" --policy-name inline \
			--policy-document "{\"Version\":\"2012-10-17\",\"Statement\":$3}" >/dev/null
	fi
}
S3_STMT="{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}"
SECRET_STMT="{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"${SECRET_ARN}\"}"
KMS_STMT="{\"Effect\":\"Allow\",\"Action\":\"kms:Decrypt\",\"Resource\":\"${KEY_ARN}\"}"
GOOD_TRUST="$(trust "$CONNECTOR_ARN_GLOB" "$ACCOUNT")"

R_OK="awsbox-xfer-ok-${TS}"
R_NOS3="awsbox-xfer-nos3-${TS}"
R_NOSECRET="awsbox-xfer-nosecret-${TS}"
R_NOKMS="awsbox-xfer-nokms-${TS}"
R_TRUST="awsbox-xfer-trust-${TS}"
mk_role "$R_OK" "$GOOD_TRUST" "[${S3_STMT},${SECRET_STMT},${KMS_STMT}]"
mk_role "$R_NOS3" "$GOOD_TRUST" "[${SECRET_STMT},${KMS_STMT}]"
mk_role "$R_NOSECRET" "$GOOD_TRUST" "[${S3_STMT},${KMS_STMT}]"
mk_role "$R_NOKMS" "$GOOD_TRUST" "[${S3_STMT},${SECRET_STMT}]"
mk_role "$R_TRUST" "$(trust "arn:aws:transfer:${REGION}:999999999999:connector/*" "999999999999")" "[${S3_STMT},${SECRET_STMT},${KMS_STMT}]"
mk_role "$LOG_ROLE" "$GOOD_TRUST" \
	"[{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}]"
arn_of() { aws iam get-role --role-name "$1" --query Role.Arn --output text; }

# --- control plane ---
CID="$(aws transfer create-connector --url "$SFTP_URL" --access-role "$(arn_of "$R_OK")" \
	--logging-role "$(arn_of "$LOG_ROLE")" \
	--sftp-config "UserSecretId=${SECRET_ARN}" \
	--tags Key=tenant,Value=acme --query ConnectorId --output text)"
CONNECTORS+=("$CID")
DESC="$(aws transfer describe-connector --connector-id "$CID")"
echo "$DESC" | python3 -c "import json,sys; c=json.load(sys.stdin)['Connector']; sys.exit(0 if c['Url']=='${SFTP_URL}' and c['ConnectorId']=='${CID}' and c['Arn'].endswith('connector/${CID}') and c['SftpConfig']['UserSecretId']=='${SECRET_ARN}' else 1)"
check "create/describe-connector round-trips url, arn, secret id" $?

aws transfer list-connectors --query "Connectors[?ConnectorId=='${CID}'].Url" --output text | grep -q "$SFTP_URL"
check "list-connectors shows the connector" $?

aws transfer test-connection --connector-id "$CID" --query Status --output text | grep -qx ERROR
check "test-connection before trusting the host key: ERROR" $?

# What `ssh-keyscan` would give an operator (older AWS CLI models drop TestConnection's HostKey).
HOST_KEY="$(sftp_sh 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $1" "$2}')"
[[ -n "$HOST_KEY" ]]

aws transfer update-connector --connector-id "$CID" --sftp-config "UserSecretId=${SECRET_ARN},TrustedHostKeys=\"${HOST_KEY}\"" >/dev/null
aws transfer test-connection --connector-id "$CID" --query Status --output text | grep -qx OK
check "test-connection after update-connector TrustedHostKeys: OK" $?

# --- transfer helpers ---
start_transfer() { # connector-id -> transfer id
	aws transfer start-file-transfer --connector-id "$1" \
		--send-file-paths "/${BUCKET}/${OBJ_KEY}" --remote-directory-path /upload \
		--query TransferId --output text
}
wait_result() { # connector-id transfer-id -> prints JSON of the first result once terminal
	local out
	for _ in $(seq 1 60); do
		out="$(aws transfer list-file-transfer-results --connector-id "$1" --transfer-id "$2" --query 'FileTransferResults[0]' --output json)"
		case "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["StatusCode"])')" in
		COMPLETED | FAILED)
			echo "$out"
			return 0
			;;
		esac
		sleep 1
	done
	echo "$out"
	return 1
}
remote_has() { sftp_sh "cat /home/awsbox/upload/$(basename "$OBJ_KEY")" 2>/dev/null | grep -q "awsbox transfer out ${TS}"; }
remote_clear() { sftp_sh "rm -f /home/awsbox/upload/$(basename "$OBJ_KEY")" >/dev/null 2>&1 || true; }
sad() { # label role-arn expected-regex [host-key-override]
	local c t r
	c="$(aws transfer create-connector --url "$SFTP_URL" --access-role "$2" \
		--sftp-config "UserSecretId=${SECRET_ARN},TrustedHostKeys=\"${4:-$HOST_KEY}\"" --query ConnectorId --output text)"
	CONNECTORS+=("$c")
	remote_clear
	t="$(start_transfer "$c")"
	r="$(wait_result "$c" "$t")" || true
	echo "     $r"
	echo "$r" | python3 -c "import json,re,sys; r=json.load(sys.stdin); sys.exit(0 if r['StatusCode']=='FAILED' and re.search(r'$3', r['FailureCode']+' '+r['FailureMessage']) else 1)" && ! remote_has
	check "$1" $?
}

# --- happy: Lambda creates the tenant connector at runtime, then sends ---
# shellcheck disable=SC1091
source "$SLICE/lambda.sh"
slice_deploy
remote_clear
P="$(slice_invoke onboard "{\"tenant\":\"acme\",\"url\":\"${SFTP_URL}\",\"secretId\":\"${SECRET_ARN}\",\"accessRole\":\"$(arn_of "$R_OK")\",\"loggingRole\":\"$(arn_of "$LOG_ROLE")\"}")"
echo "onboard: $P"
TENANT_CID="$(echo "$P" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("connectorId",""))')"
[[ -n "$TENANT_CID" ]] && CONNECTORS+=("$TENANT_CID")
echo "$P" | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if p.get("ok") and p.get("status")=="OK" else 1)'
check "Lambda onboards a tenant connector (create + test-connection + trust host key)" $?

P="$(slice_invoke send "{\"connectorId\":\"${TENANT_CID}\",\"path\":\"/${BUCKET}/${OBJ_KEY}\",\"remoteDir\":\"/upload\"}")"
echo "send: $P"
echo "$P" | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if p.get("ok") and p.get("statusCode")=="COMPLETED" else 1)' && remote_has
check "Lambda start-file-transfer: object lands on the remote SFTP host" $?

LOGS="$(aws logs filter-log-events --log-group-name "/aws/transfer/${TENANT_CID}" --query 'events[].message' --output text 2>/dev/null || true)"
echo "$LOGS" | grep -q SEND_FILE_COMPLETED && echo "$LOGS" | grep -q "$OBJ_KEY"
check "transfer events in CloudWatch Logs /aws/transfer/<connector-id>" $?

# Same connector, CLI path (admin) — also happy
remote_clear
T="$(start_transfer "$CID")"
R="$(wait_result "$CID" "$T")" || true
echo "$R" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["StatusCode"]=="COMPLETED" else 1)' && remote_has
check "CLI start-file-transfer: object lands on the remote SFTP host" $?

# --- sad ---
sad "sad/authz: access role without s3:GetObject -> FAILED, nothing on the host" "$(arn_of "$R_NOS3")" 'ACCESS_DENIED_S3'
sad "sad/authz: access role without secretsmanager:GetSecretValue -> FAILED, nothing on the host" "$(arn_of "$R_NOSECRET")" 'ACCESS_DENIED_SECRET'
sad "sad/authz: access role without kms:Decrypt on the secret's CMK -> FAILED" "$(arn_of "$R_NOKMS")" 'ACCESS_DENIED_SECRET'
sad "sad/authz: access role trust scoped to another account's connectors -> FAILED" "$(arn_of "$R_TRUST")" 'ACCESS_ROLE_TRUST'
sad "sad/other: wrong trusted host key -> FAILED" "$(arn_of "$R_OK")" 'HOST_KEY_NOT_TRUSTED' "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDwrong"

P="$(slice_invoke_nopassrole onboard "{\"tenant\":\"nopass\",\"url\":\"${SFTP_URL}\",\"secretId\":\"${SECRET_ARN}\",\"accessRole\":\"$(arn_of "$R_OK")\"}")"
echo "no-passrole onboard: $P"
echo "$P" | grep -qiE 'AccessDenied|not authorized' && ! echo "$P" | grep -q '"ok": *true'
check "sad/authz: Lambda role without iam:PassRole -> CreateConnector denied" $?

aws transfer delete-connector --connector-id "$CID" >/dev/null
aws transfer describe-connector --connector-id "$CID" >/dev/null 2>&1 && R=0 || R=1
check "delete-connector: describe afterwards fails" $((1 - R))

[[ "$FAILS" == 0 ]] || { echo "FAILED: ${FAILS} check(s)" >&2; exit 1; }
echo "OK: Transfer connector sends s3://${BUCKET}/${OBJ_KEY} to ${SFTP_URL}"
