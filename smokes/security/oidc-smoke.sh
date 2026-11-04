#!/usr/bin/env bash
# OIDC AssumeRoleWithWebIdentity conditions + iam:PassRole / iam:PassedToService.
# Happy: sub repo:org/app:environment:prod assumes the tight role; repo:org/* assumes any repo.
# Sad: feature ref denied on the tight role; other org denied on the wildcard; wrong aud denied.
# Sad: PassRole to states denied when PassedToService is events only.
# Happy: PassRole to events allowed; iam:GetRole allowed only for aws:ResourceTag/env=prod.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_SESSION_TOKEN
TS="$(date +%s)"
KEEP="${AWSBOX_OIDC_KEEP:-0}"
PROV_ARN="" PROD_ROLE="" WILD_ROLE="" PASS_ROLE="" TAGGED_ROLE="" PLAIN_ROLE=""
USER="awsbox-oidc-${TS}"
POLICY_NAME="AwsboxOidc-${TS}"
POLICY_ARN="" USER_KEY=""
RULE="awsbox-oidc-rule-${TS}"
SM_ARN=""
WORK="${TMPDIR:-/tmp}/awsbox-oidc-$$"
mkdir -p "$WORK"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
mint() { python3 "$ROOT/bin/oidc-mint.py" "$@"; }
# Test RSA key is gitignored; mint generates key+JWKS on first use.
python3 "$ROOT/bin/oidc-mint.py" --ensure-only
cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$SM_ARN" ]] && aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1 || true
	aws events remove-targets --rule "$RULE" --ids "1" >/dev/null 2>&1 || true
	aws events delete-rule --name "$RULE" >/dev/null 2>&1 || true
	[[ -n "$USER_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	for role in "$PROD_ROLE" "$WILD_ROLE" "$PASS_ROLE" "$TAGGED_ROLE" "$PLAIN_ROLE"; do
		[[ -n "$role" ]] && aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
	done
	[[ -n "$PROV_ARN" ]] && aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$PROV_ARN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect_deny() {
	local label="$1" outfile="$2"
	local rc
	set +e
	rc="$(cat "$outfile.rc")"
	set -e
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; cat "$outfile" >&2; exit 1; }
	grep -qiE "$3" "$outfile" || { echo "FAIL: ${label}: $(cat "$outfile")" >&2; exit 1; }
	echo "OK: ${label}"
}

PROV_ARN="$(aws iam create-open-id-connect-provider \
	--url https://awsbox.local/oidc \
	--thumbprint-list 0123456789012345678901234567890123456789 \
	--client-id-list sts.amazonaws.com other-aud \
	--query OpenIDConnectProviderArn --output text)"

python3 - "$WORK/prod-trust.json" "$PROV_ARN" <<'PY'
import json, sys
path, arn = sys.argv[1], sys.argv[2]
doc = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Federated": arn},
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "awsbox.local/oidc:aud": "sts.amazonaws.com",
                "awsbox.local/oidc:sub": "repo:org/app:environment:prod",
            }
        },
    }],
}
open(path, "w").write(json.dumps(doc))
PY
python3 - "$WORK/wild-trust.json" "$PROV_ARN" <<'PY'
import json, sys
path, arn = sys.argv[1], sys.argv[2]
doc = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Federated": arn},
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {"awsbox.local/oidc:aud": "sts.amazonaws.com"},
            "StringLike": {"awsbox.local/oidc:sub": "repo:org/*"},
        },
    }],
}
open(path, "w").write(json.dumps(doc))
PY

PROD_ROLE="awsbox-oidc-prod-${TS}"
WILD_ROLE="awsbox-oidc-wild-${TS}"
aws iam create-role --role-name "$PROD_ROLE" --assume-role-policy-document "file://${WORK}/prod-trust.json" >/dev/null
aws iam create-role --role-name "$WILD_ROLE" --assume-role-policy-document "file://${WORK}/wild-trust.json" >/dev/null
PROD_ARN="$(aws iam get-role --role-name "$PROD_ROLE" --query 'Role.Arn' --output text)"
WILD_ARN="$(aws iam get-role --role-name "$WILD_ROLE" --query 'Role.Arn' --output text)"

assume() {
	local arn="$1" token="$2" outfile="$3"
	set +e
	aws sts assume-role-with-web-identity \
		--role-arn "$arn" \
		--role-session-name "oidc-${TS}" \
		--web-identity-token "$token" \
		--output json >"$outfile" 2>&1
	echo $? >"${outfile}.rc"
	set -e
}

PROD_TOKEN="$(mint --sub 'repo:org/app:environment:prod')"
FEATURE_TOKEN="$(mint --sub 'repo:org/app:ref:refs/heads/feature')"
OTHER_REPO_TOKEN="$(mint --sub 'repo:org/other:ref:refs/heads/feature')"
OTHER_ORG_TOKEN="$(mint --sub 'repo:other/app:environment:prod')"
BAD_AUD_TOKEN="$(mint --sub 'repo:org/app:environment:prod' --aud other-aud)"
# Flip a signature character so verification cannot succeed by accident.
SIG="${PROD_TOKEN##*.}"
REST="${PROD_TOKEN%.*}"
if [[ "${SIG:0:1}" == "A" ]]; then
	TAMPERED="${REST}.B${SIG:1}"
else
	TAMPERED="${REST}.A${SIG:1}"
fi

assume "$PROD_ARN" "$PROD_TOKEN" "$WORK/prod-ok.json"
[[ "$(cat "$WORK/prod-ok.json.rc")" -eq 0 ]] || { echo "FAIL: prod sub denied" >&2; cat "$WORK/prod-ok.json" >&2; exit 1; }
python3 - "$WORK/prod-ok.json" "$PROD_ROLE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
creds = doc["Credentials"]
arn = doc["AssumedRoleUser"]["Arn"]
role = sys.argv[2]
if role not in arn:
    raise SystemExit(f"assumed arn {arn} missing {role}")
open(sys.argv[1] + ".env", "w").write(
    f"{creds['AccessKeyId']} {creds['SecretAccessKey']} {creds['SessionToken']}\n"
)
PY
read -r SAK SSK SST <"$WORK/prod-ok.json.env"
IDENT="$(AWS_ACCESS_KEY_ID="$SAK" AWS_SECRET_ACCESS_KEY="$SSK" AWS_SESSION_TOKEN="$SST" \
	aws sts get-caller-identity --query Arn --output text)"
echo "$IDENT" | grep -q "$PROD_ROLE" || { echo "FAIL: caller $IDENT" >&2; exit 1; }
echo "OK: prod sub assumed ${PROD_ROLE}"

assume "$PROD_ARN" "$FEATURE_TOKEN" "$WORK/feature.json"
expect_deny "feature ref denied on prod role" "$WORK/feature.json" "AccessDenied|not authorized"
assume "$PROD_ARN" "$BAD_AUD_TOKEN" "$WORK/badaud.json"
expect_deny "wrong aud denied on prod role" "$WORK/badaud.json" "AccessDenied|not authorized"
assume "$PROD_ARN" "$TAMPERED" "$WORK/bad-sig.json"
expect_deny "bad signature rejected" "$WORK/bad-sig.json" "InvalidIdentityToken|signature"

assume "$WILD_ARN" "$PROD_TOKEN" "$WORK/wild-prod.json"
[[ "$(cat "$WORK/wild-prod.json.rc")" -eq 0 ]] || { echo "FAIL: wildcard rejected prod sub" >&2; cat "$WORK/wild-prod.json" >&2; exit 1; }
assume "$WILD_ARN" "$OTHER_REPO_TOKEN" "$WORK/wild-other.json"
[[ "$(cat "$WORK/wild-other.json.rc")" -eq 0 ]] || { echo "FAIL: wildcard rejected other repo" >&2; cat "$WORK/wild-other.json" >&2; exit 1; }
echo "OK: repo:org/* accepted prod and other repo (risky pattern)"
assume "$WILD_ARN" "$OTHER_ORG_TOKEN" "$WORK/wild-org.json"
expect_deny "other org denied on repo:org/*" "$WORK/wild-org.json" "AccessDenied|not authorized"

PASS_ROLE="awsbox-oidc-pass-${TS}"
TAGGED_ROLE="awsbox-oidc-tagged-${TS}"
PLAIN_ROLE="awsbox-oidc-plain-${TS}"
PASS_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["events.amazonaws.com","states.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
SVC_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$PASS_ROLE" --assume-role-policy-document "$PASS_TRUST" >/dev/null
aws iam create-role --role-name "$TAGGED_ROLE" --assume-role-policy-document "$SVC_TRUST" --tags Key=env,Value=prod >/dev/null
aws iam create-role --role-name "$PLAIN_ROLE" --assume-role-policy-document "$SVC_TRUST" >/dev/null
PASS_ARN="$(aws iam get-role --role-name "$PASS_ROLE" --query 'Role.Arn' --output text)"

python3 - "$WORK/user-policy.json" "$PASS_ARN" <<'PY'
import json, sys
path, role_arn = sys.argv[1], sys.argv[2]
doc = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "events:PutRule",
                "events:PutTargets",
                "events:RemoveTargets",
                "events:DeleteRule",
                "states:CreateStateMachine",
                "stepfunctions:CreateStateMachine",
            ],
            "Resource": "*",
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": role_arn,
            "Condition": {"StringEquals": {"iam:PassedToService": "events.amazonaws.com"}},
        },
        {
            "Effect": "Allow",
            "Action": "iam:GetRole",
            "Resource": "*",
            "Condition": {"StringEquals": {"aws:ResourceTag/env": "prod"}},
        },
    ],
}
open(path, "w").write(json.dumps(doc))
PY
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${WORK}/user-policy.json" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
USER_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$KEYS_JSON")"
USER_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$KEYS_JSON")"
as_user() { AWS_ACCESS_KEY_ID="$USER_KEY" AWS_SECRET_ACCESS_KEY="$USER_SECRET" aws "$@"; }

as_user iam get-role --role-name "$TAGGED_ROLE" --query 'Role.RoleName' --output text | grep -qx "$TAGGED_ROLE"
echo "OK: GetRole allowed for aws:ResourceTag/env=prod"
set +e
TAG_OUT="$(as_user iam get-role --role-name "$PLAIN_ROLE" 2>&1)"
TAG_RC=$?
set -e
[[ "$TAG_RC" -ne 0 ]] || { echo "FAIL: untagged GetRole succeeded" >&2; exit 1; }
echo "$TAG_OUT" | grep -qiE 'AccessDenied|not authorized' || { echo "FAIL: $TAG_OUT" >&2; exit 1; }
echo "OK: GetRole denied without aws:ResourceTag/env=prod"

as_user events put-rule --name "$RULE" --event-pattern '{"source":["awsbox.oidc"]}' >/dev/null
as_user events put-targets --rule "$RULE" --targets "Id=1,Arn=arn:aws:lambda:${REGION}:000000000000:function:none,RoleArn=${PASS_ARN}" >/dev/null
echo "OK: PassRole allowed for iam:PassedToService=events.amazonaws.com"

DEF='{"StartAt":"Hi","States":{"Hi":{"Type":"Pass","End":true}}}'
set +e
SFN_OUT="$(as_user stepfunctions create-state-machine --name "awsbox-oidc-sfn-${TS}" --definition "$DEF" --role-arn "$PASS_ARN" 2>&1)"
SFN_RC=$?
set -e
if [[ "$SFN_RC" -eq 0 ]]; then
	SM_ARN="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("stateMachineArn",""))' <<<"$SFN_OUT" 2>/dev/null || true)"
	echo "FAIL: PassRole to states succeeded" >&2
	exit 1
fi
echo "$SFN_OUT" | grep -q 'iam:PassRole' || { echo "FAIL: $SFN_OUT" >&2; exit 1; }
echo "OK: PassRole denied for iam:PassedToService=states.amazonaws.com"
echo "OK: oidc smoke"
