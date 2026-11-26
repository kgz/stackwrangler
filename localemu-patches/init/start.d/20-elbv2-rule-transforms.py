"""Store ELBv2 listener-rule Transforms on moto FakeListenerRule (#766).

moto accepts CreateRule/ModifyRule Transforms via the botocore model but
does not persist them, so DescribeRules never returns Transforms and
Terraform plans forever. Patch create/modify + FakeListenerRule so the
LocalEmu elbv2 provider and serializer round-trip url-rewrite /
host-header-rewrite (and ResetTransforms).
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.elbv2_rule_transforms")


def _install() -> None:
    from moto.elbv2.exceptions import InvalidModifyRuleArgumentsError, RuleNotFoundError
    from moto.elbv2.models import ELBv2Backend, FakeAction, FakeListenerRule
    from moto.elbv2.responses import ELBV2Response

    if getattr(FakeListenerRule, "_sw_transforms_patched", False):
        return

    _orig_init = FakeListenerRule.__init__

    def _init(self, listener_arn, arn, conditions, priority, actions, transforms=None):
        _orig_init(self, listener_arn, arn, conditions, priority, actions)
        self.transforms = list(transforms or [])

    FakeListenerRule.__init__ = _init  # type: ignore[method-assign]
    FakeListenerRule._sw_transforms_patched = True

    _orig_create = ELBv2Backend.create_rule

    def _create_rule(
        self,
        listener_arn,
        conditions,
        priority,
        actions,
        tags=None,
        transforms=None,
    ):
        rule = _orig_create(
            self,
            listener_arn,
            conditions,
            priority,
            actions,
            tags=tags,
        )
        rule.transforms = list(transforms or [])
        return rule

    ELBv2Backend.create_rule = _create_rule  # type: ignore[method-assign]

    def _modify_rule(
        self,
        rule_arn,
        conditions,
        actions,
        transforms=None,
        reset_transforms=False,
    ):
        fake_actions = [FakeAction(action) for action in (actions or [])]
        transforms_provided = transforms is not None
        if (
            not conditions
            and not fake_actions
            and not transforms_provided
            and not reset_transforms
        ):
            raise InvalidModifyRuleArgumentsError()
        rules = self.describe_rules(listener_arn=None, rule_arns=[rule_arn])
        if not rules:
            raise RuleNotFoundError()
        rule = rules[0]

        if conditions:
            self._validate_conditions(conditions)
            rule.conditions = conditions
        if fake_actions:
            self._validate_actions(fake_actions)
            rule.actions = fake_actions
        if not hasattr(rule, "transforms"):
            rule.transforms = []
        if reset_transforms:
            rule.transforms = []
        if transforms_provided:
            rule.transforms = list(transforms or [])
        return rule

    ELBv2Backend.modify_rule = _modify_rule  # type: ignore[method-assign]

    def _create_rule_response(self):
        from moto.core.responses import ActionResult

        params = self._get_params()
        rule = self.elbv2_backend.create_rule(
            listener_arn=params["ListenerArn"],
            conditions=params["Conditions"],
            priority=params["Priority"],
            actions=params["Actions"],
            tags=params.get("Tags"),
            transforms=params.get("Transforms"),
        )
        return ActionResult({"Rules": [rule]})

    def _modify_rule_response(self):
        from moto.core.responses import ActionResult

        params = self._get_params()
        rule_arn = self._get_param("RuleArn")
        conditions = params.get("Conditions", [])
        actions = params.get("Actions", [])
        reset = params.get("ResetTransforms")
        reset_transforms = reset is True or reset == "true" or reset == "True"
        rule = self.elbv2_backend.modify_rule(
            rule_arn=rule_arn,
            conditions=conditions,
            actions=actions,
            transforms=params.get("Transforms"),
            reset_transforms=reset_transforms,
        )
        return ActionResult({"Rules": [rule]})

    ELBV2Response.create_rule = _create_rule_response  # type: ignore[method-assign]
    ELBV2Response.modify_rule = _modify_rule_response  # type: ignore[method-assign]
    LOG.info("elbv2 listener-rule Transforms patch installed (#766)")


try:
    _install()
except Exception:
    LOG.warning("elbv2 Transforms patch failed", exc_info=True)
