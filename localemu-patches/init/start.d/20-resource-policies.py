"""Wire resource-policy evaluation into the IAM enforcer.

Secrets Manager documents, KMS key-policy delegation, cross-account
"both must allow", and implicit CMK checks for Secrets Manager and SSM.
S3 bucket policies already load in the enforcer; role-ARN matching is
patched so an assumed-role session matches a policy that names the role.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.resource_policies")

_ACCESS_DENIED_EXCEPTION = {
    "secretsmanager": "AccessDeniedException",
    "kms": "AccessDeniedException",
    "ssm": "AccessDeniedException",
}


def _service_name(context) -> str:
    service = getattr(context, "service", None)
    name = getattr(service, "service_name", None)
    return name if isinstance(name, str) else ""


def _install() -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.iam_enforcement import enforcer, evaluator
    from localemu.services.iam_enforcement import resource_policies as rp
    from localemu.services.iam_enforcement.evaluator import Decision
    from localemu.services.iam_enforcement.identity import resolve_caller

    orig_match = evaluator._arn_or_account_matches

    def _arn_or_account_matches(principal_value, caller):
        if orig_match(principal_value, caller):
            return True
        if getattr(caller, "principal_type", None) == "AssumedRole" and caller.role_name:
            role_arn = f"arn:aws:iam::{caller.account_id}:role/{caller.role_name}"
            if principal_value == role_arn:
                return True
        return False

    evaluator._arn_or_account_matches = _arn_or_account_matches

    orig_build = enforcer.build_resource_arn

    def build_resource_arn(service, operation, request_params, region, account_id):
        params = dict(request_params or {})
        region = region or "us-east-1"
        if service == "kms" and not params.get("KeyId"):
            key_id = rp.key_id_from_ciphertext(params.get("CiphertextBlob"))
            if key_id:
                params["KeyId"] = key_id
        arn = orig_build(service, operation, params, region, account_id)
        if service == "secretsmanager":
            ident = params.get("SecretId") or params.get("Name") or arn
            canon = rp.canonical_secret_arn(str(ident), account_id, region)
            if canon:
                return canon
        if service == "kms":
            key_ref = params.get("KeyId") or arn
            canon = rp.canonical_kms_arn(str(key_ref), account_id, region)
            if canon:
                return canon
        return arn

    enforcer.build_resource_arn = build_resource_arn

    orig_get = enforcer._get_resource_policy

    def _get_resource_policy(service, resource_arn, account_id, region):
        if service == "secretsmanager":
            return rp.load_secretsmanager_policy_doc(
                resource_arn, account_id, region or "us-east-1",
            )
        if service == "kms":
            return rp.load_kms_key_policy(resource_arn, account_id, region or "us-east-1")
        return orig_get(service, resource_arn, account_id, region)

    enforcer._get_resource_policy = _get_resource_policy

    orig_eval = evaluator.PolicyEvaluator.evaluate

    def evaluate(self, caller, action, resource, conditions, resource_policy=None):
        if getattr(caller, "principal_type", None) != "Root":
            if isinstance(action, str) and action.startswith("kms:") and resource_policy:
                return rp.evaluate_kms_crypto(
                    orig_eval, self, caller, action, resource, conditions, resource_policy,
                )
            if resource_policy:
                region = (conditions or {}).get("aws:RequestedRegion") or "us-east-1"
                owner = rp.resource_owner_account(
                    action, resource or "", caller.account_id, region,
                )
                if owner != caller.account_id:
                    return rp.evaluate_both_required(
                        orig_eval, self, caller, action, resource, conditions, resource_policy,
                    )
        return orig_eval(self, caller, action, resource, conditions, resource_policy)

    evaluator.PolicyEvaluator.evaluate = evaluate

    def _recoded(exc, context):
        wanted = _ACCESS_DENIED_EXCEPTION.get(_service_name(context))
        if wanted and exc.code == "AccessDenied":
            return CommonServiceException(
                code=wanted,
                message=exc.message,
                status_code=exc.status_code,
                sender_fault=exc.sender_fault,
            )
        return None

    def _implicit_kms(self, context) -> None:
        enforce, audit, enabled = self._read_mode()
        if not enabled:
            return
        service_name = _service_name(context)
        operation = getattr(getattr(context, "operation", None), "name", None)
        if service_name not in ("secretsmanager", "ssm") or not operation:
            return
        access_key = enforcer._extract_access_key(context)
        if self._is_internal_call(context, access_key):
            return
        account_id = context.account_id or "000000000000"
        region = context.region or "us-east-1"
        caller = resolve_caller(access_key, account_id, region) if access_key else None
        if not caller or caller.principal_type in ("Root", "Anonymous"):
            return
        checks = rp.implicit_kms_checks(
            service_name, operation, context.service_request, account_id, region,
        )
        if not checks:
            return
        conditions = enforcer._build_conditions(context, caller)
        for kms_action, key_id in checks:
            key_arn = rp.canonical_kms_arn(key_id, account_id, region)
            policy = None
            if key_arn:
                policy = enforcer._get_resource_policy("kms", key_arn, account_id, region)
            if not key_arn or not policy:
                decision = Decision.IMPLICIT_DENY
                resource = key_arn or key_id
            else:
                decision = self.evaluator.evaluate(
                    caller, kms_action, key_arn, conditions, policy,
                )
                resource = key_arn
            if decision == Decision.ALLOW:
                continue
            wire = (
                f"User: {caller.arn} is not authorized to perform: "
                f"{kms_action} on resource: {resource}"
            )
            if audit and not enforce:
                LOG.warning("IAM AUDIT DENY: %s", wire)
                return
            LOG.info("IAM DENY: %s", wire)
            raise CommonServiceException(
                code="AccessDeniedException",
                message=wire,
                status_code=403,
            )

    orig_call = enforcer.IAMEnforcementHandler.__call__

    def _call(self, chain, context, response):
        try:
            orig_call(self, chain, context, response)
        except CommonServiceException as exc:
            recoded = _recoded(exc, context)
            if recoded is not None:
                raise recoded from None
            raise
        _implicit_kms(self, context)

    enforcer.IAMEnforcementHandler.__call__ = _call
    LOG.info("awsbox resource policy hooks applied")


_install()
