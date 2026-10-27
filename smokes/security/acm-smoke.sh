#!/usr/bin/env bash
# ACM request/import + attach ARN to API GW custom domain and ALB HTTPS listener.
# Slice shape: examples/serverless-v3-rest/slices/acm/
# TLS handshake presenting the ACM keypair is [#242] — this smoke stores/describes only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
DOMAIN="api.example.test"
SLICE="$ROOT/examples/serverless-v3-rest/slices/acm"
KEEP="${AWSBOX_ACM_KEEP:-0}"
WORK="${TMPDIR:-/tmp}/awsbox-acm-${TS}"
CERT=""
IMPORT_CERT=""
API_ID=""
DOMAIN_CREATED=0
VPC=""
SUB_A=""
SUB_B=""
SG=""
TG=""
LB=""
LIS=""
DENY_USER=""
DENY_KEY=""
DENY_POLICY=""

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	local rc=$?
	set +e
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && exit "$rc"
	[[ -n "$LIS" ]] && aws elbv2 delete-listener --listener-arn "$LIS" >/dev/null 2>&1
	[[ -n "$LB" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1
	[[ -n "$TG" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1
	[[ "$DOMAIN_CREATED" == "1" ]] && aws apigateway delete-domain-name --domain-name "$DOMAIN" >/dev/null 2>&1
	[[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1
	[[ -n "$CERT" ]] && aws acm delete-certificate --certificate-arn "$CERT" >/dev/null 2>&1
	[[ -n "$IMPORT_CERT" ]] && aws acm delete-certificate --certificate-arn "$IMPORT_CERT" >/dev/null 2>&1
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1
	if [[ -n "$DENY_KEY" && -n "$DENY_USER" ]]; then
		aws iam delete-access-key --user-name "$DENY_USER" --access-key-id "$DENY_KEY" >/dev/null 2>&1
	fi
	[[ -n "$DENY_POLICY" && -n "$DENY_USER" ]] && \
		aws iam detach-user-policy --user-name "$DENY_USER" --policy-arn "$DENY_POLICY" >/dev/null 2>&1
	[[ -n "$DENY_POLICY" ]] && aws iam delete-policy --policy-arn "$DENY_POLICY" >/dev/null 2>&1
	[[ -n "$DENY_USER" ]] && aws iam delete-user --user-name "$DENY_USER" >/dev/null 2>&1
	exit "$rc"
}
trap cleanup EXIT

[[ -f "$SLICE/README.md" ]] || fail "missing slice $SLICE/README.md"
mkdir -p "$WORK"

echo "==> sad: deny-user RequestCertificate → AccessDenied"
DENY_USER="awsbox-acm-deny-${TS}"
aws iam create-user --user-name "$DENY_USER" >/dev/null
POLICY_DOC="$WORK/deny.json"
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"acm:RequestCertificate","Resource":"*"}]}
EOF
DENY_POLICY="$(aws iam create-policy --policy-name "AwsboxDenyAcmRequest-${TS}" \
	--policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$DENY_USER" --policy-arn "$DENY_POLICY" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$DENY_USER" --output json)"
DENY_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENY_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
set +e
DENY_OUT="$(
	AWS_ACCESS_KEY_ID="$DENY_KEY" AWS_SECRET_ACCESS_KEY="$DENY_SECRET" \
		aws acm request-certificate --domain-name "deny-${TS}.example.test" 2>&1
)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || fail "RequestCertificate succeeded for deny user"
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' || fail "$DENY_OUT"
echo "OK: acm RequestCertificate AccessDenied"

echo "==> request DNS-validated cert for ${DOMAIN}"
CERT="$(aws acm request-certificate \
	--domain-name "$DOMAIN" \
	--validation-method DNS \
	--query CertificateArn --output text)"
[[ "$CERT" == arn:aws:acm:* ]] || fail "bad request ARN: $CERT"

DESC="$(aws acm describe-certificate --certificate-arn "$CERT" --output json)"
echo "$DESC" | CERT="$CERT" DOMAIN="$DOMAIN" python3 -c '
import json, os, sys
c = json.load(sys.stdin)["Certificate"]
assert c["CertificateArn"] == os.environ["CERT"], c
assert c["DomainName"] == os.environ["DOMAIN"], c
print("status", c.get("Status") or c.get("CertificateStatus") or "?")
'
LIST="$(aws acm list-certificates --output json)"
echo "$LIST" | CERT="$CERT" python3 -c '
import json, os, sys
arns = [x["CertificateArn"] for x in json.load(sys.stdin).get("CertificateSummaryList") or []]
want = os.environ["CERT"]
assert want in arns, arns
'
echo "OK: request/describe/list ${CERT}"

echo "==> import self-signed certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-days 1 -subj "/CN=import.${DOMAIN}" >/dev/null 2>&1
IMPORT_CERT="$(aws acm import-certificate \
	--certificate "fileb://${WORK}/cert.pem" \
	--private-key "fileb://${WORK}/key.pem" \
	--query CertificateArn --output text)"
[[ "$IMPORT_CERT" == arn:aws:acm:* ]] || fail "bad import ARN: $IMPORT_CERT"
IMP_DOM="$(aws acm describe-certificate --certificate-arn "$IMPORT_CERT" \
	--query 'Certificate.DomainName' --output text)"
[[ "$IMP_DOM" == "import.${DOMAIN}" ]] || fail "imported domain $IMP_DOM"
echo "OK: import ${IMPORT_CERT}"

echo "==> API GW custom domain accepts cert ARN"
API_ID="$(aws apigateway create-rest-api --name "awsbox-acm-${TS}" --query id --output text)"
aws apigateway create-domain-name --domain-name "$DOMAIN" \
	--regional-certificate-arn "$CERT" \
	--endpoint-configuration types=REGIONAL >/dev/null
DOMAIN_CREATED=1
GOT_CERT="$(aws apigateway get-domain-name --domain-name "$DOMAIN" \
	--query regionalCertificateArn --output text)"
[[ "$GOT_CERT" == "$CERT" ]] || fail "domain cert $GOT_CERT != $CERT"
echo "OK: custom domain ${DOMAIN} → ${CERT}"

echo "==> ALB HTTPS listener stores cert ARN"
VPC="$(aws ec2 create-vpc --cidr-block 10.74.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.74.1.0/24 \
	--availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.74.2.0/24 \
	--availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "awsbox-acm-${TS}" --description acm \
	--vpc-id "$VPC" --query 'GroupId' --output text)"
TG="$(aws elbv2 create-target-group --name "acm-tg-${TS}" --protocol HTTP --port 80 \
	--vpc-id "$VPC" --target-type ip \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
LB="$(aws elbv2 create-load-balancer --name "acm-alb-${TS}" --type application \
	--scheme internet-facing --subnets "$SUB_A" "$SUB_B" --security-groups "$SG" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol HTTPS --port 443 \
	--certificates "CertificateArn=${CERT}" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"
LIS_CERT="$(aws elbv2 describe-listeners --listener-arns "$LIS" \
	--query 'Listeners[0].Certificates[0].CertificateArn' --output text)"
[[ "$LIS_CERT" == "$CERT" ]] || fail "listener cert $LIS_CERT != $CERT"
echo "OK: ALB HTTPS listener stores ${CERT}"

echo "OK: acm smoke (request/import/describe/list + API domain + ALB HTTPS)"
echo "NOTE: TLS handshake with the ACM keypair is Debt [#242]"
