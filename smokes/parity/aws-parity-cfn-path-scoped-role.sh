#!/usr/bin/env bash
# Dual-side: CFN path-scoped deploy role GetRole deny → DELETE_FAILED; pathless grant → CREATE_COMPLETE (#679).
# LocalEmu + real AWS. IAM + CFN only.
# Usage: ./smokes/parity/aws-parity-cfn-path-scoped-role.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
#
# Cost (real): IAM roles/policies + short-lived CFN stacks — ~$0.
# Residual if teardown fails: leftover IAM roles/policies named sw-psr-* (delete manually).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cloudformation/path-scoped-role"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/parity-sides.sh"

KEEP="${AWSBOX_PARITY_KEEP:-0}"
TS="$(date +%s)"

run_side() {
	local label="$1"
	local account role_path role_prefix app_role app_role_ok deploy_role boundary_name
	local stack_deny stack_ok boundary_arn workdir
	local st blob app_arn

	role_path="/app/dev/"
	role_prefix="sw-psr-${label}-${TS}"
	app_role="${role_prefix}-app"
	app_role_ok="${role_prefix}-app-ok"
	deploy_role="${role_prefix}-deploy"
	boundary_name="${role_prefix}-bound"
	stack_deny="${role_prefix}-deny"
	stack_ok="${role_prefix}-ok"
	boundary_arn=""
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/cfn-psr-${label}.XXXXXX")"

	teardown() {
		[[ "$KEEP" == "1" ]] && {
			echo "KEEP=1 — left ${label} stacks=${stack_deny},${stack_ok}"
			return 0
		}
		echo "==> ${label}: teardown"
		# Pathless grant so CFN --role-arn can finish delete of orphan roles.
		[[ -f "$workdir/pathless.json" ]] && \
			aws_cli iam put-role-policy --role-name "$deploy_role" --policy-name pathless \
				--policy-document "file://${workdir}/pathless.json" >/dev/null 2>&1 || true
		sleep 3
		aws_cli cloudformation delete-stack --stack-name "$stack_deny" \
			--deletion-mode FORCE_DELETE_STACK >/dev/null 2>&1 \
			|| aws_cli cloudformation delete-stack --stack-name "$stack_deny" >/dev/null 2>&1 || true
		aws_cli cloudformation delete-stack --stack-name "$stack_ok" \
			--deletion-mode FORCE_DELETE_STACK >/dev/null 2>&1 \
			|| aws_cli cloudformation delete-stack --stack-name "$stack_ok" >/dev/null 2>&1 || true
		local i st
		for i in $(seq 1 60); do
			st="$(aws_cli cloudformation describe-stacks --stack-name "$stack_deny" \
				--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)"
			[[ "$st" == "GONE" || "$st" == "DELETE_COMPLETE" ]] && break
			sleep 2
		done
		for i in $(seq 1 60); do
			st="$(aws_cli cloudformation describe-stacks --stack-name "$stack_ok" \
				--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)"
			[[ "$st" == "GONE" || "$st" == "DELETE_COMPLETE" ]] && break
			sleep 2
		done
		local r arn
		for r in "$app_role" "$app_role_ok" "$deploy_role"; do
			aws_cli iam delete-role-policy --role-name "$r" --policy-name inline >/dev/null 2>&1 || true
			aws_cli iam delete-role-policy --role-name "$r" --policy-name smoke >/dev/null 2>&1 || true
			aws_cli iam delete-role-policy --role-name "$r" --policy-name pathless >/dev/null 2>&1 || true
			for arn in $(aws_cli iam list-attached-role-policies --role-name "$r" \
				--query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
				[[ -n "$arn" && "$arn" != "None" ]] && \
					aws_cli iam detach-role-policy --role-name "$r" --policy-arn "$arn" >/dev/null 2>&1 || true
			done
			aws_cli iam delete-role --role-name "$r" >/dev/null 2>&1 || true
		done
		[[ -n "$boundary_arn" ]] && aws_cli iam delete-policy --policy-arn "$boundary_arn" >/dev/null 2>&1 || true
		rm -rf "$workdir"
	}

	wait_stack_terminal() {
		local stack="$1" timeout="${2:-120}" i st
		for i in $(seq 1 "$timeout"); do
			st="$(aws_cli cloudformation describe-stacks --stack-name "$stack" \
				--query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)"
			case "$st" in
				*_IN_PROGRESS|MISSING)
					;;
				*COMPLETE|*FAILED)
					echo "$st"
					return 0
					;;
			esac
			sleep 2
		done
		echo "TIMEOUT"
		return 1
	}

	events_blob() {
		aws_cli cloudformation describe-stack-events --stack-name "$1" \
			--query 'StackEvents[].{L:LogicalResourceId,S:ResourceStatus,R:ResourceStatusReason}' \
			--output text 2>/dev/null || true
	}

	account="$(aws_cli sts get-caller-identity --query Account --output text)"

	cat >"$workdir/boundary.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:GetCallerIdentity",
    "Resource": "*"
  }]
}
EOF
	boundary_arn="$(aws_cli iam create-policy \
		--policy-name "$boundary_name" \
		--policy-document "file://${workdir}/boundary.json" \
		--query Policy.Arn --output text)"

	# CFN service principal trust — create-stack --role-arn (PassRole), not caller AssumeRole.
	cat >"$workdir/cfn-trust.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "cloudformation.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
	cat >"$workdir/path-only.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${account}:role/app/dev/*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:CreatePolicy",
      "Resource": "*"
    }
  ]
}
EOF
	cat >"$workdir/pathless.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole"
    ],
    "Resource": "arn:aws:iam::${account}:role/${role_prefix}-*"
  }]
}
EOF

	echo "==> ${label}: create path-scoped CFN deploy role"
	aws_cli iam create-role --role-name "$deploy_role" \
		--assume-role-policy-document "file://${workdir}/cfn-trust.json" >/dev/null
	aws_cli iam put-role-policy --role-name "$deploy_role" --policy-name inline \
		--policy-document "file://${workdir}/path-only.json" >/dev/null

	# IAM / CFN role propagation on real AWS
	sleep 12

	deploy_arn="arn:aws:iam::${account}:role/${deploy_role}"

	echo "==> ${label}: sad create-stack --role-arn (expect DELETE_FAILED + iam:GetRole)"
	aws_cli cloudformation create-stack \
		--stack-name "$stack_deny" \
		--role-arn "$deploy_arn" \
		--template-body "file://${EX}/template.yaml" \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameters \
		"ParameterKey=RoleName,ParameterValue=${app_role}" \
		"ParameterKey=RolePath,ParameterValue=${role_path}" \
		"ParameterKey=PermissionsBoundaryArn,ParameterValue=${boundary_arn}" >/dev/null

	st="$(wait_stack_terminal "$stack_deny" 120)"
	echo "    status=${st}"
	# LocalEmu: DELETE_FAILED. Real: ROLLBACK_FAILED (cannot DeleteRolePolicy/GetRole)
	# or ROLLBACK_COMPLETE when the role never materialised.
	case "$st" in
		DELETE_FAILED|ROLLBACK_FAILED|ROLLBACK_COMPLETE) ;;
		*)
			echo "FAIL (${label}): expected DELETE_FAILED|ROLLBACK_FAILED|ROLLBACK_COMPLETE, got ${st}" >&2
			events_blob "$stack_deny" >&2
			teardown
			return 1
			;;
	esac
	blob="$(events_blob "$stack_deny")"
	echo "$blob" | grep -qiE 'iam:GetRole' || {
		echo "FAIL (${label}): expected iam:GetRole in events" >&2
		echo "$blob" >&2
		teardown
		return 1
	}
	echo "$blob" | grep -qiE 'not authorized|AccessDenied' || {
		echo "FAIL (${label}): expected AccessDenied in events" >&2
		echo "$blob" >&2
		teardown
		return 1
	}
	# LocalEmu cites role/<name>; real IAM error text uses "role <name>".
	echo "$blob" | grep -qE "role(/| )${app_role}" || {
		echo "FAIL (${label}): expected pathless role ${app_role} in deny reason" >&2
		echo "$blob" >&2
		teardown
		return 1
	}
	echo "OK (${label}): path-scoped-only → iam:GetRole AccessDenied (${st})"

	aws_cli cloudformation delete-stack --stack-name "$stack_deny" \
		--deletion-mode FORCE_DELETE_STACK >/dev/null 2>&1 \
		|| aws_cli cloudformation delete-stack --stack-name "$stack_deny" >/dev/null 2>&1 || true
	aws_cli iam put-role-policy --role-name "$deploy_role" --policy-name pathless \
		--policy-document "file://${workdir}/pathless.json" >/dev/null
	sleep 12

	echo "==> ${label}: happy create-stack --role-arn after pathless grant"
	aws_cli cloudformation create-stack \
		--stack-name "$stack_ok" \
		--role-arn "$deploy_arn" \
		--template-body "file://${EX}/template.yaml" \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameters \
		"ParameterKey=RoleName,ParameterValue=${app_role_ok}" \
		"ParameterKey=RolePath,ParameterValue=${role_path}" \
		"ParameterKey=PermissionsBoundaryArn,ParameterValue=${boundary_arn}" >/dev/null

	st="$(wait_stack_terminal "$stack_ok" 120)"
	echo "    status=${st}"
	[[ "$st" == "CREATE_COMPLETE" ]] || {
		echo "FAIL (${label}): expected CREATE_COMPLETE, got ${st}" >&2
		events_blob "$stack_ok" >&2
		teardown
		return 1
	}

	app_arn="$(aws_cli iam get-role --role-name "$app_role_ok" --query 'Role.Arn' --output text)"
	case "$app_arn" in
	*"role/app/dev/${app_role_ok}") ;;
	*)
		echo "FAIL (${label}): role ARN missing path: ${app_arn}" >&2
		teardown
		return 1
		;;
	esac
	echo "OK (${label}): pathless grant → CREATE_COMPLETE (${app_arn})"
	teardown
}

parity_run_sides
echo "OK: cfn path-scoped role parity complete (ts=${TS})"
