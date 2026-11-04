#!/usr/bin/env bash
# EC2 IMDSv2 instance-profile creds, first-boot user data, SSM SendCommand.
# Happy: instance reads a secret with its role; user data file; send-command stdout.
# Sad: role without secretsmanager:GetSecretValue → AccessDenied;
#      caller without ssm:SendCommand → AccessDenied.
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

TS="$(date +%s)"
ROLE="awsbox-imds-${TS}"
ROLE_DENY="awsbox-imds-deny-${TS}"
SECRET="awsbox-imds-${TS}"
SECRET_VALUE="imds-secret-${TS}"
SSM_USER="awsbox-ssm-deny-${TS}"
KEEP="${AWSBOX_EC2_KEEP:-0}"
UD="$(mktemp)"
IID=""
IID_DENY=""
DENIED_KEY=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -f "$UD"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$IID" ]] && aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true
	[[ -n "$IID_DENY" ]] && aws ec2 terminate-instances --instance-ids "$IID_DENY" >/dev/null 2>&1 || true
	aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
	aws iam delete-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-secret >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE_DENY" --role-name "$ROLE_DENY" >/dev/null 2>&1 || true
	aws iam delete-instance-profile --instance-profile-name "$ROLE_DENY" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE_DENY" >/dev/null 2>&1 || true
	aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 || true
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$SSM_USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$SSM_USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '#!/bin/sh\necho awsbox-userdata-ok > /tmp/awsbox-userdata.txt\n' >"$UD"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ALLOW='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"*"}]}'

aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name allow-secret --policy-document "$ALLOW" >/dev/null
aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null

aws iam create-role --role-name "$ROLE_DENY" --assume-role-policy-document "$TRUST" >/dev/null
aws iam create-instance-profile --instance-profile-name "$ROLE_DENY" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_DENY" --role-name "$ROLE_DENY" >/dev/null

aws secretsmanager create-secret --name "$SECRET" --secret-string "$SECRET_VALUE" >/dev/null

META='HttpTokens=required,HttpEndpoint=enabled,InstanceMetadataTags=enabled'
TAGS='ResourceType=instance,Tags=[{Key=Name,Value=awsbox-imds},{Key=Env,Value=smoke}]'

IID="$(aws ec2 run-instances \
	--image-id ami-ubuntu-22.04 \
	--instance-type t3.micro \
	--iam-instance-profile "Name=${ROLE}" \
	--user-data "file://${UD}" \
	--metadata-options "$META" \
	--tag-specifications "$TAGS" \
	--query 'Instances[0].InstanceId' --output text)"
echo "INSTANCE=${IID}"

IID_DENY="$(aws ec2 run-instances \
	--image-id ami-ubuntu-22.04 \
	--instance-type t3.micro \
	--iam-instance-profile "Name=${ROLE_DENY}" \
	--metadata-options "$META" \
	--query 'Instances[0].InstanceId' --output text)"
echo "DENY_INSTANCE=${IID_DENY}"

for id in "$IID" "$IID_DENY"; do
	STATE=""
	for _ in $(seq 1 45); do
		STATE="$(aws ec2 describe-instances --instance-ids "$id" \
			--query 'Reservations[0].Instances[0].State.Name' --output text)"
		[[ "$STATE" == "running" ]] && break
		[[ "$STATE" == "terminated" || "$STATE" == "shutting-down" ]] && {
			echo "FAIL: ${id} ${STATE}" >&2
			exit 1
		}
		sleep 2
	done
	[[ "$STATE" == "running" ]] || { echo "FAIL: ${id} not running (${STATE})" >&2; exit 1; }
done

CNAME="localemu-ec2-${IID}"
HELLO=""
for _ in $(seq 1 30); do
	HELLO="$(docker exec "$CNAME" cat /tmp/awsbox-userdata.txt 2>/dev/null || true)"
	[[ -n "$HELLO" ]] && break
	sleep 1
done
echo "$HELLO" | grep -qx 'awsbox-userdata-ok' || {
	echo "FAIL: user data did not write /tmp/awsbox-userdata.txt (${HELLO:-empty})" >&2
	exit 1
}
echo "OK: user data"

read_secret() {
	local cname="$1" role="$2" check_name="${3:-0}"
	docker exec -e "SECRET_ID=${SECRET}" -e "ROLE_NAME=${role}" -e "CHECK_NAME=${check_name}" "$cname" sh -c '
set -e
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://169.254.169.254/latest/meta-data/instance-id || true)
if [ "$CODE" != "401" ]; then
	echo "FAIL: IMDSv1 expected 401 when HttpTokens=required, got ${CODE}" >&2
	exit 1
fi
TOKEN=$(curl -sf --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
[ -n "$TOKEN" ]
ROLE=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
[ "$ROLE" = "$ROLE_NAME" ]
IDENT=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document)
echo "$IDENT" | grep -q "$LOCALEMU_INSTANCE_ID"
if [ "$CHECK_NAME" = "1" ]; then
	curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Name | grep -qx awsbox-imds
fi
CREDS=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}")
export AWS_ACCESS_KEY_ID=$(printf "%s" "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"AccessKeyId\"])")
export AWS_SECRET_ACCESS_KEY=$(printf "%s" "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"SecretAccessKey\"])")
export AWS_SESSION_TOKEN=$(printf "%s" "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"Token\"])")
exec aws --endpoint-url "$AWS_ENDPOINT_URL" secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text
'
}

GOT=""
for _ in $(seq 1 20); do
	set +e
	GOT="$(read_secret "$CNAME" "$ROLE" 1 2>/tmp/awsbox-imds-read.err)"
	RC=$?
	set -e
	[[ "$RC" -eq 0 && "$GOT" == "$SECRET_VALUE" ]] && break
	sleep 2
done
[[ "$GOT" == "$SECRET_VALUE" ]] || {
	echo "FAIL: instance did not read secret (got '${GOT:-}')" >&2
	cat /tmp/awsbox-imds-read.err >&2 || true
	exit 1
}
echo "OK: instance-profile GetSecretValue"

CNAME_DENY="localemu-ec2-${IID_DENY}"
set +e
DENY_OUT="$(read_secret "$CNAME_DENY" "$ROLE_DENY" 2>&1)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || { echo "FAIL: deny role read the secret (${DENY_OUT})" >&2; exit 1; }
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized' || {
	echo "FAIL: deny role was not AccessDenied" >&2
	echo "$DENY_OUT" >&2
	exit 1
}
echo "OK: instance-profile AccessDenied"

INFO="$(aws ssm describe-instance-information --output json)"
printf '%s' "$INFO" | IID="$IID" python3 -c 'import json,os,sys; ids={i["InstanceId"] for i in json.load(sys.stdin).get("InstanceInformationList",[])}; raise SystemExit(0 if os.environ["IID"] in ids else 1)'
echo "OK: SSM agent online"

CMD="$(aws ssm send-command \
	--instance-ids "$IID" \
	--document-name AWS-RunShellScript \
	--parameters 'commands=["echo ssm-ok-208"]' \
	--query 'Command.CommandId' --output text)"
STATUS=""
STDOUT=""
for _ in $(seq 1 20); do
	INV="$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --output json 2>/dev/null || true)"
	STATUS="$(printf '%s' "$INV" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Status",""))' 2>/dev/null || true)"
	if [[ "$STATUS" == "Success" || "$STATUS" == "Failed" || "$STATUS" == "TimedOut" ]]; then
		STDOUT="$(printf '%s' "$INV" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardOutputContent",""))')"
		break
	fi
	sleep 1
done
[[ "$STATUS" == "Success" ]] || { echo "FAIL: ssm status ${STATUS}" >&2; exit 1; }
printf '%s' "$STDOUT" | grep -q 'ssm-ok-208' || { echo "FAIL: ssm stdout '${STDOUT}'" >&2; exit 1; }
echo "OK: ssm send-command"

aws iam create-user --user-name "$SSM_USER" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$SSM_USER" --output json)"
DENIED_KEY="$(printf '%s' "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(printf '%s' "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
SSM_DENY="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
	aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
	--parameters 'commands=["echo no"]' 2>&1)"
SSM_RC=$?
set -e
[[ "$SSM_RC" -ne 0 ]] || { echo "FAIL: ssm send-command succeeded without permission" >&2; exit 1; }
echo "$SSM_DENY" | grep -qiE 'AccessDenied|not authorized' || {
	echo "FAIL: ssm deny was not AccessDenied" >&2
	echo "$SSM_DENY" >&2
	exit 1
}
echo "OK: ssm SendCommand AccessDenied"
echo "OK: ec2 imds/ssm ${IID}"
