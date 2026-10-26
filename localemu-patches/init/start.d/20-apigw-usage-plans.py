"""Enforce usage plan throttle and quota on REST API keys, and revoke on DeleteApiKey.

The stock handler accepts any key that sits in a usage plan for the stage and
ignores the plan's limits. Per key and plan:

* With ``apiKeySource`` AUTHORIZER the key is the authorizer's ``usageIdentifierKey``.
* ``throttle`` (rateLimit / burstLimit) is a token bucket; an empty bucket is 429
  ``Too Many Requests``.
* ``quota`` (limit / period / offset) counts allowed requests in a UTC period (day,
  week starting Sunday, month starting on the 1st); past the limit is 429
  ``Limit Exceeded``. ``offset`` is subtracted from the limit in the first period only.
  Throttled requests are not counted.

DeleteApiKey also drops the key from every usage plan, as AWS does; otherwise the
dangling plan key would fail the lookup with a 500.
"""

from __future__ import annotations

import logging
import threading
import time
from datetime import datetime, timedelta, timezone

LOG = logging.getLogger("localemu.awsbox.apigw_usage_plans")

_LOCK = threading.Lock()
_BUCKETS: dict = {}
_QUOTA: dict = {}
_FIRST_WINDOW: dict = {}


def quota_window_start(now: datetime, period: str) -> datetime:
    """UTC start of the quota period: midnight, the preceding Sunday, or the 1st."""
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "WEEK":
        return today - timedelta(days=(today.weekday() + 1) % 7)
    if period == "MONTH":
        return today.replace(day=1)
    return today


class Limits:
    buckets = _BUCKETS
    quota = _QUOTA

    def throttled(self, plan: dict, key_id: str) -> bool:
        throttle = plan.get("throttle") or {}
        rate, burst = throttle.get("rateLimit"), throttle.get("burstLimit")
        if rate is None and burst is None:
            return False
        rate = float(rate if rate is not None else burst)
        burst = float(burst if burst is not None else max(rate, 1))
        now = time.monotonic()
        with _LOCK:
            state = self.buckets.get((plan["id"], key_id))
            if state is None or state["shape"] != (rate, burst):
                state = {"shape": (rate, burst), "tokens": burst, "at": now}
                self.buckets[(plan["id"], key_id)] = state
            state["tokens"] = min(burst, state["tokens"] + (now - state["at"]) * rate)
            state["at"] = now
            if state["tokens"] < 1.0:
                return True
            state["tokens"] -= 1.0
            return False

    def over_quota(self, plan: dict, key_id: str) -> bool:
        quota = plan.get("quota") or {}
        limit = quota.get("limit")
        if not limit:
            return False
        window = quota_window_start(datetime.now(timezone.utc), quota.get("period") or "DAY")
        with _LOCK:
            # offset is requests subtracted from the limit in the plan's first period
            # (first seen here, as plans carry no creation time)
            first = _FIRST_WINDOW.setdefault(plan["id"], window)
            allowed = int(limit) - (int(quota.get("offset") or 0) if first == window else 0)
            state = self.quota.get((plan["id"], key_id))
            if state is None or state["window"] != window:
                state = {"window": window, "used": 0}
                self.quota[(plan["id"], key_id)] = state
            if state["used"] >= allowed:
                return True
            state["used"] += 1
            return False


def _install() -> None:
    from moto.apigateway.models import APIGatewayBackend

    from localemu.services.apigateway.next_gen.execute_api.gateway_response import (
        QuotaExceededError,
        ThrottledError,
    )
    from localemu.services.apigateway.next_gen.execute_api.handlers import api_key_validation
    from localemu.services.apigateway.next_gen.execute_api.moto_helpers import (
        get_api_key,
        get_usage_plan_keys,
        get_usage_plans,
    )

    handler = api_key_validation.ApiKeyValidationHandler
    if getattr(handler, "_awsbox_usage_plans", False):
        return

    limits = Limits()

    def validate_api_key(self, api_key_value, context):
        account, region = context.account_id, context.region
        for plan in get_usage_plans(account_id=account, region_name=region):
            staged = any(
                s.get("stage") == context.stage and s.get("apiId") == context.api_id
                for s in plan.get("apiStages") or []
            )
            if not staged:
                continue
            for plan_key in get_usage_plan_keys(
                usage_plan_id=plan["id"], account_id=account, region_name=region
            ):
                if plan_key["value"] != api_key_value:
                    continue
                try:
                    api_key = get_api_key(api_key_id=plan_key["id"], account_id=account, region_name=region)
                except KeyError:
                    return None
                if not api_key["enabled"]:
                    return None
                if limits.throttled(plan, api_key["id"]):
                    raise ThrottledError("Too Many Requests")
                if limits.over_quota(plan, api_key["id"]):
                    raise QuotaExceededError("Limit Exceeded")
                return api_key
        return None

    orig_call = handler.__call__

    def __call__(self, chain, context, response):
        # Authorizers run first; their usageIdentifierKey is the key when apiKeySource is AUTHORIZER.
        rest_api = context.deployment.rest_api.rest_api
        identity = context.context_variables.get("identity")
        usage_key = (context.context_variables.get("authorizer") or {}).get("usageIdentifierKey")
        if rest_api.get("apiKeySource") == "AUTHORIZER" and usage_key and identity is not None:
            identity.setdefault("apiKey", usage_key)
        return orig_call(self, chain, context, response)

    handler.validate_api_key = validate_api_key
    handler.__call__ = __call__
    handler._awsbox_usage_plans = True

    orig_delete = APIGatewayBackend.delete_api_key

    def delete_api_key(self, api_key_id):
        orig_delete(self, api_key_id)
        for plan_keys in self.usage_plan_keys.values():
            plan_keys.pop(api_key_id, None)

    APIGatewayBackend.delete_api_key = delete_api_key
    LOG.info("awsbox REST usage plan throttle/quota applied")


_install()
