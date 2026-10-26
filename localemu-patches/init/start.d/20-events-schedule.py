"""Scheduled EventBridge rules: honour disable/delete, require invoke permission (#297).

Upstream registers a scheduler job per PutTargets that never looks at the rule
again: DisableRule and DeleteRule leave it firing, a rule created DISABLED can
never be enabled, and each extra PutTargets adds another job. Rule -> Lambda
delivery also skips the function resource policy, so a rule without a
`lambda:InvokeFunction` grant for events.amazonaws.com still fires.

Under IAM_ENFORCEMENT=1 the missing grant drops the delivery; with `soft` it is
only logged.
"""

from __future__ import annotations

import dataclasses
import logging
import os

LOG = logging.getLogger("localemu.awsbox.events_schedule")

_EVENTS_PRINCIPAL = "events.amazonaws.com"


def _iam_mode() -> str:
    return os.environ.get("IAM_ENFORCEMENT", "").strip().lower()


def _function_policy(sender) -> tuple[dict | None, str, str]:
    from localemu.services.lambda_.api_utils import function_locators_from_arn
    from localemu.services.lambda_.invocation.models import lambda_stores

    arn = sender.target["Arn"]
    name, qualifier, account, region = function_locators_from_arn(arn)
    account = account or sender.target_account_id
    region = region or sender.target_region
    function = lambda_stores[account][region].functions.get(name) if name else None
    if function is None:
        return None, account, region
    permission = function.permissions.get(qualifier or "$LATEST")
    if permission is None:
        return None, account, region
    return dataclasses.asdict(permission.policy), account, region


def _invoke_granted(sender) -> bool:
    from localemu.services.iam_enforcement import resource_policies as rp

    policy, account, region = _function_policy(sender)
    effect = rp.evaluate_service_delivery(
        _EVENTS_PRINCIPAL,
        "lambda:InvokeFunction",
        sender.target["Arn"],
        policy,
        sender.rule_arn,
        account,
        region,
    )
    return effect == "allow"


def _patch_lambda_target() -> None:
    from localemu.services.events.target import LambdaTargetSender, TargetSender

    if getattr(LambdaTargetSender, "_awsbox_invoke_permission", False):
        return

    def process_event(self, event, trace_header):
        mode = _iam_mode()
        if mode in ("1", "soft") and self.caller_service_principal == "events":
            try:
                granted = _invoke_granted(self)
            except Exception as e:
                LOG.warning("events->lambda permission lookup failed: %s", e)
                granted = mode != "1"
            if not granted:
                LOG.warning(
                    "IAM %s events->lambda: rule=%s target=%s lacks lambda:InvokeFunction for %s",
                    "DENY" if mode == "1" else "AUDIT DENY",
                    self.rule_arn,
                    self.target["Arn"],
                    _EVENTS_PRINCIPAL,
                )
                if mode == "1":
                    return
        return TargetSender.process_event(self, event, trace_header)

    LambdaTargetSender.process_event = process_event
    LambdaTargetSender._awsbox_invoke_permission = True


def _patch_schedule_jobs() -> None:
    from localemu.services.events.provider import EventsProvider
    from localemu.services.events.rule import RuleService
    from localemu.services.events.scheduler import JobScheduler

    if getattr(RuleService, "_awsbox_schedule_jobs", False):
        return

    original_job_function = EventsProvider._get_scheduled_rule_job_function
    original_delete = EventsProvider._delete_rule_services

    def job_function(self, account_id, region, rule):
        inner = original_job_function(self, account_id, region, rule)

        def func(*args, **kwargs):
            if rule.state == "DISABLED" or rule.arn not in self._rule_services_store:
                return None
            return inner(*args, **kwargs)

        return func

    def create_schedule_job(self, schedule_job_sender_func):
        scheduler = JobScheduler.instance()
        previous = getattr(self, "job_id", None)
        if previous:
            scheduler.cancel_job(previous)
        # Enabled state is checked per tick by job_function, so ENABLE works later.
        self.job_id = scheduler.add_job(schedule_job_sender_func, self.schedule_cron, True)

    def delete_rule_services(self, rules):
        doomed = [rules] if hasattr(rules, "arn") else list(rules.values())
        for rule in doomed:
            service = self._rule_services_store.get(rule.arn)
            job_id = getattr(service, "job_id", None)
            if job_id:
                JobScheduler.instance().cancel_job(job_id)
        return original_delete(self, rules)

    EventsProvider._get_scheduled_rule_job_function = job_function
    EventsProvider._delete_rule_services = delete_rule_services
    RuleService.create_schedule_job = create_schedule_job
    RuleService._awsbox_schedule_jobs = True


def _patch() -> None:
    _patch_schedule_jobs()
    _patch_lambda_target()
    LOG.info("awsbox events schedule/disable + lambda invoke permission patch applied")


_patch()
