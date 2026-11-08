"""Wire resource-policy evaluation into the IAM enforcer.

Secrets Manager documents, KMS key-policy delegation, cross-account
"both must allow", and implicit CMK checks for Secrets Manager and SSM.
S3 bucket policies already load in the enforcer; role-ARN matching is
patched so an assumed-role session matches a policy that names the role.

DynamoDB table resource policies (#516) load from moto and are evaluated
with identity policies (explicit deny wins). ``aws:SourceVpce`` is set from
the caller's subnet gateway-endpoint route (or a VPCE proxy source IP).

Also: SNS→SQS delivery evaluates the queue resource policy. connect_to()
marks the SendMessage as an internal hop and the stock IAM enforcer
bypasses it; AWS still requires the queue policy to Allow
sns.amazonaws.com (usually with aws:SourceArn). We gate in the SNS
publisher so a deny becomes a silent drop (same as AWS).

Queues encrypted with the AWS-managed key ``alias/aws/sqs`` also fail
delivery on real AWS (that key policy cannot grant SNS); we refuse those
the same way and record a failed delivery.

A customer-managed key is refused the same way unless its key policy
Allows ``sns.amazonaws.com`` both ``kms:GenerateDataKey`` and
``kms:Decrypt``. A grant on the key still delivers.
"""

from __future__ import annotations

import logging
import os
import threading

LOG = logging.getLogger("localemu.awsbox.resource_policies")

_ACCESS_DENIED_EXCEPTION = {
    "secretsmanager": "AccessDeniedException",
    "kms": "AccessDeniedException",
    "ssm": "AccessDeniedException",
    "dynamodb": "AccessDeniedException",
}

_deny_layer = threading.local()

_NEGATED_CONDITION_OPS = frozenset({
    "StringNotEquals",
    "StringNotEqualsIgnoreCase",
    "StringNotLike",
    "NumericNotEquals",
    "DateNotEquals",
    "NotIpAddress",
    "ArnNotEquals",
    "ArnNotLike",
})


def _service_name(context) -> str:
    service = getattr(context, "service", None)
    name = getattr(service, "service_name", None)
    return name if isinstance(name, str) else ""


def _iam_mode():
    mode = os.environ.get("IAM_ENFORCEMENT", "").strip().lower()
    return mode == "1", mode == "soft", (mode == "1" or mode == "soft")


def _patch_condition_not_equals() -> None:
    """AWS Not* operators: missing key matches; multi-value lists are AND'd (#516)."""
    from localemu.services.iam_enforcement import condition_evaluator as ce

    orig_matches = ce.matches_conditions

    def matches_conditions(statement: dict, context: dict) -> bool:
        conditions = statement.get("Condition")
        if not conditions:
            return True

        for operator, condition_block in conditions.items():
            if_exists = operator.endswith("IfExists")
            base_operator = operator.replace("IfExists", "") if if_exists else operator

            set_op = None
            if base_operator.startswith("ForAllValues:"):
                set_op = "all"
                base_operator = base_operator[len("ForAllValues:"):]
            elif base_operator.startswith("ForAnyValue:"):
                set_op = "any"
                base_operator = base_operator[len("ForAnyValue:"):]

            compare_fn = ce._OPERATORS.get(base_operator)
            if not compare_fn:
                LOG.warning("Unknown IAM condition operator: %s", operator)
                return False

            for condition_key, condition_values in condition_block.items():
                if isinstance(condition_values, str):
                    condition_values = [condition_values]

                condition_values = [
                    ce._substitute_policy_variables(str(v), context)
                    for v in condition_values
                ]

                context_value = context.get(condition_key)
                if isinstance(context_value, list) and len(context_value) == 0:
                    context_value = None

                if context_value is None:
                    if if_exists:
                        continue
                    if base_operator == "Null":
                        if not ce._safe_compare(compare_fn, None, condition_values[0]):
                            return False
                        continue
                    # AWS: Not* operators match when the key is absent.
                    if base_operator in _NEGATED_CONDITION_OPS:
                        continue
                    return False

                if set_op:
                    ctx_values = (
                        context_value if isinstance(context_value, list) else [context_value]
                    )
                    if set_op == "all":
                        for cv in ctx_values:
                            if not any(
                                ce._safe_compare(compare_fn, cv, cond_v)
                                for cond_v in condition_values
                            ):
                                return False
                    elif set_op == "any":
                        if not any(
                            ce._safe_compare(compare_fn, cv, cond_v)
                            for cv in ctx_values
                            for cond_v in condition_values
                        ):
                            return False
                elif base_operator in _NEGATED_CONDITION_OPS:
                    # Multi-value Not*: key must differ from every listed value.
                    if not all(
                        ce._safe_compare(compare_fn, context_value, v)
                        for v in condition_values
                    ):
                        return False
                else:
                    if not any(
                        ce._safe_compare(compare_fn, context_value, v)
                        for v in condition_values
                    ):
                        return False

        return True

    matches_conditions._awsbox_not_equals = True  # type: ignore[attr-defined]
    ce.matches_conditions = matches_conditions
    # Re-bind copies imported at module load time.
    for mod_name in (
        "localemu.services.iam_enforcement.evaluator",
        "localemu.services.iam_enforcement.resource_policies",
    ):
        try:
            import importlib

            mod = importlib.import_module(mod_name)
            if hasattr(mod, "matches_conditions"):
                setattr(mod, "matches_conditions", matches_conditions)
        except Exception:
            LOG.debug("matches_conditions rebind skipped for %s", mod_name, exc_info=True)
    _ = orig_matches


def _install() -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.iam_enforcement import enforcer, evaluator
    from localemu.services.iam_enforcement import resource_policies as rp
    from localemu.services.iam_enforcement.evaluator import Decision
    from localemu.services.iam_enforcement.identity import resolve_caller

    _patch_condition_not_equals()

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
        if service == "dynamodb":
            return rp.load_dynamodb_resource_policy(
                resource_arn, account_id, region or "us-east-1",
            )
        if service == "secretsmanager":
            return rp.load_secretsmanager_policy_doc(
                resource_arn, account_id, region or "us-east-1",
            )
        if service == "kms":
            return rp.load_kms_key_policy(resource_arn, account_id, region or "us-east-1")
        return orig_get(service, resource_arn, account_id, region)

    enforcer._get_resource_policy = _get_resource_policy

    orig_build_conditions = enforcer._build_conditions

    def _build_conditions(context, caller):
        conditions = orig_build_conditions(context, caller)
        try:
            from localemu.services.ec2.docker.vpc_routing import resolve_source_vpce

            service = _service_name(context)
            # SourceVpce is mostly meaningful for gateway-endpoint services.
            if service in ("dynamodb", "s3"):
                remote = getattr(getattr(context, "request", None), "remote_addr", None)
                vpce = resolve_source_vpce(
                    remote,
                    getattr(caller, "account_id", None) or context.account_id or "000000000000",
                    context.region or "us-east-1",
                    service=service,
                )
                if vpce:
                    conditions["aws:SourceVpce"] = vpce
        except Exception:
            LOG.debug("aws:SourceVpce resolution failed", exc_info=True)
        return conditions

    enforcer._build_conditions = _build_conditions

    orig_eval = evaluator.PolicyEvaluator.evaluate
    # sts:AssumeRole uses the role trust policy (STS), not this both-must-allow path.
    _CROSS_ACCOUNT_RP_SERVICES = frozenset({
        "s3", "secretsmanager", "kms", "sqs", "sns", "lambda", "events",
    })

    def evaluate(self, caller, action, resource, conditions, resource_policy=None):
        _deny_layer.source = None
        if getattr(caller, "principal_type", None) != "Root":
            if isinstance(action, str) and action.startswith("kms:") and resource_policy:
                decision = rp.evaluate_kms_crypto(
                    orig_eval, self, caller, action, resource, conditions, resource_policy,
                )
            elif resource_policy:
                region = (conditions or {}).get("aws:RequestedRegion") or "us-east-1"
                owner = rp.resource_owner_account(
                    action, resource or "", caller.account_id, region,
                )
                if owner != caller.account_id:
                    decision = rp.evaluate_both_required(
                        orig_eval, self, caller, action, resource, conditions, resource_policy,
                    )
                else:
                    decision = orig_eval(
                        self, caller, action, resource, conditions, resource_policy,
                    )
            else:
                decision = orig_eval(
                    self, caller, action, resource, conditions, resource_policy,
                )
        else:
            decision = orig_eval(
                self, caller, action, resource, conditions, resource_policy,
            )
        if decision == Decision.EXPLICIT_DENY and resource_policy:
            if rp.resource_policy_effect(
                resource_policy, caller, action, resource or "", conditions,
            ) == "deny":
                _deny_layer.source = "resource-based policy"
            else:
                _deny_layer.source = "identity-based policy"
        return decision
        region = (conditions or {}).get("aws:RequestedRegion") or "us-east-1"
        owner = rp.resource_owner_account(
            action, resource or "", caller.account_id, region,
        )
        cross = owner != caller.account_id
        service = action.split(":", 1)[0] if isinstance(action, str) and ":" in action else ""
        is_kms = service == "kms"

        # Cross-account resource policies: identity Allow alone is never enough
        # (including Root). Missing document → implicit deny in the helpers.
        if is_kms and (resource_policy is not None or cross):
            return rp.evaluate_kms_crypto(
                orig_eval, self, caller, action, resource, conditions, resource_policy,
            )
        if cross and service in _CROSS_ACCOUNT_RP_SERVICES:
            return rp.evaluate_both_required(
                orig_eval, self, caller, action, resource, conditions, resource_policy,
            )
        return orig_eval(self, caller, action, resource, conditions, resource_policy)

    evaluator.PolicyEvaluator.evaluate = evaluate

    def _enrich_deny_message(exc):
        source = getattr(_deny_layer, "source", None)
        msg = exc.message or ""
        if not source or "explicit deny" in msg:
            return exc
        return CommonServiceException(
            code=exc.code,
            message=f"{msg} with an explicit deny in a {source}",
            status_code=exc.status_code,
            sender_fault=exc.sender_fault,
        )

    def _recoded(exc, context):
        enriched = _enrich_deny_message(exc)
        wanted = _ACCESS_DENIED_EXCEPTION.get(_service_name(context))
        if wanted and enriched.code == "AccessDenied":
            return CommonServiceException(
                code=wanted,
                message=enriched.message,
                status_code=enriched.status_code,
                sender_fault=enriched.sender_fault,
            )
        if enriched is not exc:
            return enriched
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

    def _queue_allows_sns(queue_arn: str, topic_arn: str) -> bool:
        """True when the queue policy Allows sns.amazonaws.com from topic_arn."""
        enforce, audit, enabled = _iam_mode()
        if not enabled:
            return True
        if not queue_arn or not isinstance(queue_arn, str) or not queue_arn.startswith("arn:"):
            return False
        parts = queue_arn.split(":")
        region = parts[3] if len(parts) > 3 and parts[3] else "us-east-1"
        account_id = parts[4] if len(parts) > 4 and parts[4] else "000000000000"
        policy = enforcer._get_resource_policy("sqs", queue_arn, account_id, region)
        effect = rp.evaluate_service_delivery(
            "sns.amazonaws.com",
            "sqs:SendMessage",
            queue_arn,
            policy,
            topic_arn,
            account_id,
            region,
        )
        if effect == "allow":
            return True
        wire = (
            f"User: sns.amazonaws.com is not authorized to perform: "
            f"sqs:SendMessage on resource: {queue_arn}"
        )
        if audit and not enforce:
            LOG.warning("IAM AUDIT DENY (SNS→SQS): %s", wire)
            return True
        LOG.info("IAM DENY (SNS→SQS): %s (source=%s)", wire, topic_arn)
        return False

    def _sns_may_deliver_to_queue(queue_arn: str, topic_arn: str) -> bool:
        """Queue policy + KMS: refuse ``alias/aws/sqs`` and CMKs without an SNS grant."""
        if rp.sns_blocked_by_sqs_aws_managed_kms(queue_arn):
            LOG.info(
                "SNS→SQS refuse: queue %s uses alias/aws/sqs (source=%s)",
                queue_arn,
                topic_arn,
            )
            return False
        if rp.sns_blocked_by_sqs_cmk_policy(queue_arn, topic_arn):
            LOG.info(
                "SNS→SQS refuse: queue %s CMK policy does not allow "
                "sns.amazonaws.com kms:GenerateDataKey and kms:Decrypt (source=%s)",
                queue_arn,
                topic_arn,
            )
            return False
        return _queue_allows_sns(queue_arn, topic_arn)

    def _record_sqs_delivery_failure(sns_publisher, context, subscriber, batch: bool) -> None:
        try:
            if batch:
                for message in getattr(context, "messages", None) or []:
                    sns_publisher.store_delivery_log(
                        message,
                        subscriber,
                        success=False,
                        topic_attributes=getattr(context, "topic_attributes", None),
                    )
            else:
                sns_publisher.store_delivery_log(
                    context.message,
                    subscriber,
                    success=False,
                    topic_attributes=getattr(context, "topic_attributes", None),
                )
        except Exception:
            LOG.debug("SNS→SQS deny delivery log failed", exc_info=True)

    def _patch_sns_sqs_publishers() -> None:
        from localemu.services.sns import publisher as sns_publisher

        orig_sqs = sns_publisher.SqsTopicPublisher._publish

        def sqs_publish(self, context, subscriber):
            queue_arn = subscriber.get("Endpoint") or ""
            topic_arn = subscriber.get("TopicArn") or ""
            if not _sns_may_deliver_to_queue(queue_arn, topic_arn):
                # Mirror AWS: Subscribe succeeded; delivery is silently dropped.
                _record_sqs_delivery_failure(sns_publisher, context, subscriber, batch=False)
                return
            return orig_sqs(self, context, subscriber)

        sns_publisher.SqsTopicPublisher._publish = sqs_publish

        orig_batch = sns_publisher.SqsBatchTopicPublisher._publish

        def sqs_batch_publish(self, context, subscriber):
            queue_arn = subscriber.get("Endpoint") or ""
            topic_arn = subscriber.get("TopicArn") or ""
            if not _sns_may_deliver_to_queue(queue_arn, topic_arn):
                _record_sqs_delivery_failure(sns_publisher, context, subscriber, batch=True)
                return
            return orig_batch(self, context, subscriber)

        sns_publisher.SqsBatchTopicPublisher._publish = sqs_batch_publish

    _patch_sns_sqs_publishers()

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
    LOG.info(
        "awsbox resource policy hooks applied "
        "(SNS→SQS queue policy + alias/aws/sqs and CMK key policy gated)"
    )


_install()
