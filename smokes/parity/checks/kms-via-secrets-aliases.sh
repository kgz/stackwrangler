#!/usr/bin/env bash
# Dual-target: KMS ViaService + ResourceAliases via Secrets Manager / SSM (#666).
# Real: reuses alias/sw-parity-fixture-trust-via when present (no new CMK residual).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/parity/lib/parity-common.sh"
parity_setup

TS="$(date +%s)"
REGION="$PARITY_REGION"
WORKDIR="${TMPDIR:-/tmp}/sw-parity-kms-via-$$"
mkdir -p "$WORKDIR"
on_cleanup "rm -rf '$WORKDIR'"

FIXTURE="${AWSBOX_PARITY_KMS_KEY_ID:-alias/sw-parity-fixture-trust-via}"
ALIAS="alias/sw-parity-kms-via-${TS}"
WRONG_ALIAS="alias/sw-parity-kms-via-wrong-${TS}"
SECRET_NAME="sw-parity/kms-via-${TS}"
PARAM_NAME="/sw-parity/kms-via-${TS}"
USER="sw-parity-kms-via-${TS}"
POLICY_NAME="SwParityKmsVia-${TS}"
WRONG_POLICY_NAME="SwParityKmsViaWrong-${TS}"
SECRET_ARN=""
POLICY_ARN=""
WRONG_POLICY_ARN=""
USER_KEY=""
USER_SECRET=""

parity_resolve_kms_fixture "$FIXTURE"

# Ephemeral alias on the resolved key (deleted on cleanup; fixture key kept).
aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID" >/dev/null
on_cleanup "aws kms delete-alias --alias-name '$ALIAS'"

# Reverse order: detach/delete keys+policies before delete-user.
on_cleanup "aws iam delete-user --user-name '$USER'"
on_cleanup '[[ -n "$WRONG_POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$WRONG_POLICY_ARN"; [[ -n "$WRONG_POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$WRONG_POLICY_ARN"'
on_cleanup '[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN"; [[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN"'
on_cleanup '[[ -n "$USER_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY"'
on_cleanup "aws ssm delete-parameter --name '$PARAM_NAME'"
on_cleanup '[[ -n "$SECRET_ARN" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery'

as_user() {
	AWS_ACCESS_KEY_ID="$USER_KEY" AWS_SECRET_ACCESS_KEY="$USER_SECRET" aws "$@"
}

expect_deny() {
	local label="$1"
	shift
	set +e
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || parity_die "${label} succeeded"
	echo "$out" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny' \
		|| parity_die "${label}: ${out}"
	parity_pass "$label"
}

VIA_SM="secretsmanager.${REGION}.amazonaws.com"
VIA_SSM="ssm.${REGION}.amazonaws.com"

SECRET_ARN="$(aws secretsmanager create-secret \
	--name "$SECRET_NAME" \
	--secret-string 'kms-via-secret' \
	--kms-key-id "$ALIAS" \
	--query 'ARN' --output text)"

aws ssm put-parameter \
	--name "$PARAM_NAME" \
	--type SecureString \
	--value 'kms-via-param' \
	--key-id "$ALIAS" \
	--overwrite >/dev/null

DESCRIBE_KMS="$(aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --query 'KmsKeyId' --output text || true)"
echo "secret KmsKeyId stored as: ${DESCRIBE_KMS}"

python3 - "$WORKDIR/user-policy.json" "$VIA_SM" "$VIA_SSM" "$ALIAS" <<'PY'
import json, sys
path, via_sm, via_ssm, alias = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret",
                "ssm:GetParameter",
            ],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {
                "StringEquals": {"kms:ViaService": [via_sm, via_ssm]},
                "ForAnyValue:StringEquals": {"kms:ResourceAliases": alias},
            },
        },
    ],
}, open(path, "w"))
PY
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${WORKDIR}/user-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
USER_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$KEYS_JSON")"
USER_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$KEYS_JSON")"

# IAM access keys are eventually consistent on real AWS.
GOT=""
for _ in $(seq 1 30); do
	set +e
	GOT="$(as_user secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query 'SecretString' --output text 2>/dev/null)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 && "$GOT" == "kms-via-secret" ]] && break
	sleep 2
done
[[ "$GOT" == "kms-via-secret" ]] || parity_die "GetSecretValue failed after retries"
parity_pass "GetSecretValue allowed with kms:ViaService=${VIA_SM} and kms:ResourceAliases=${ALIAS}"

GOT_PARAM="$(as_user ssm get-parameter --name "$PARAM_NAME" --with-decryption --query 'Parameter.Value' --output text)"
[[ "$GOT_PARAM" == "kms-via-param" ]] || parity_die "GetParameter failed"
parity_pass "GetParameter allowed with kms:ViaService=${VIA_SSM} and kms:ResourceAliases=${ALIAS}"

set +e
DENY_OUT="$(as_user kms decrypt --ciphertext-blob "$(
	PT="$WORKDIR/pt.bin"
	printf 'direct' >"$PT"
	aws kms encrypt --key-id "$KEY_ID" --plaintext "fileb://${PT}" --query 'CiphertextBlob' --output text
)" 2>&1)"
DENY_RC=$?
set -e
[[ "$DENY_RC" -ne 0 ]] || parity_die "direct Decrypt succeeded"
echo "$DENY_OUT" | grep -qiE 'AccessDenied|not authorized' \
	|| parity_die "direct Decrypt: ${DENY_OUT}"
if ! echo "$DENY_OUT" | grep -q "key/${KEY_ID}" && ! echo "$DENY_OUT" | grep -q "$KEY_ARN"; then
	parity_die "deny resource not key ARN: ${DENY_OUT}"
fi
if echo "$DENY_OUT" | grep -q "key/alias/"; then
	parity_die "deny still uses key/alias/: ${DENY_OUT}"
fi
parity_pass "direct kms:Decrypt denied without ViaService (resource is key ARN)"

# Detach good policy first and wait until deny sticks (real IAM lag / no SM grant bypass).
aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
DETACHED_DENY=0
for _ in $(seq 1 45); do
	set +e
	as_user secretsmanager get-secret-value --secret-id "$SECRET_ARN" >/dev/null 2>&1
	rc=$?
	set -e
	if [[ "$rc" -ne 0 ]]; then
		DETACHED_DENY=1
		break
	fi
	sleep 2
done
[[ "$DETACHED_DENY" -eq 1 ]] || parity_die "GetSecretValue still allowed after detaching kms:Decrypt policy (grant bypass?)"

python3 - "$WORKDIR/wrong-policy.json" "$VIA_SM" "$VIA_SSM" "$WRONG_ALIAS" <<'PY'
import json, sys
path, via_sm, via_ssm, alias = sys.argv[1:]
json.dump({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret",
                "ssm:GetParameter",
            ],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {
                "StringEquals": {"kms:ViaService": [via_sm, via_ssm]},
                "ForAnyValue:StringEquals": {"kms:ResourceAliases": alias},
            },
        },
    ],
}, open(path, "w"))
PY
WRONG_POLICY_ARN="$(aws iam create-policy --policy-name "$WRONG_POLICY_NAME" --policy-document "file://${WORKDIR}/wrong-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$WRONG_POLICY_ARN" >/dev/null
parity_wait_iam 10
# Wrong alias must not restore access once the good policy is gone.
expect_deny "GetSecretValue denied when kms:ResourceAliases mismatches" \
	as_user secretsmanager get-secret-value --secret-id "$SECRET_ARN"
expect_deny "GetParameter denied when kms:ResourceAliases mismatches" \
	as_user ssm get-parameter --name "$PARAM_NAME" --with-decryption

if [[ "$CREATED_EPHEMERAL_CMK" -eq 1 && "$PARITY_TARGET" == "real" ]]; then
	echo "NOTE: ephemeral CMK created — 7d residual until PendingDeletion completes"
fi

parity_pass "kms-via-secrets-aliases"
parity_finish
