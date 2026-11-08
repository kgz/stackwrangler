"""Test assertion helper for GET /_awsl/calls (#194).

Example::

    from api_call_log_assert import assert_no_calls, assert_exactly

    assert_no_calls("my-fn", "secretsmanager:*", endpoint="http://127.0.0.1:4566")
    assert_exactly("my-fn", ["secretsmanager:GetSecretValue"], endpoint=...)
"""

from __future__ import annotations

import fnmatch
import json
import os
import urllib.parse
import urllib.request
from typing import Any


def _endpoint(endpoint: str | None) -> str:
    base = (endpoint or os.environ.get("AWSBOX_IAM_ENDPOINT") or "http://127.0.0.1:4566").rstrip(
        "/"
    )
    return f"{base}/_awsl/calls"


def fetch_calls(
    *,
    workload: str | None = None,
    service: str | None = None,
    action: str | None = None,
    result: str | None = None,
    since: str | float | None = None,
    endpoint: str | None = None,
    limit: int = 10000,
) -> list[dict[str, Any]]:
    params: dict[str, str] = {"limit": str(limit)}
    if workload:
        params["workload"] = workload
    if service:
        params["service"] = service
    if action:
        params["action"] = action
    if result:
        params["result"] = result
    if since is not None and since != "":
        params["since"] = str(since)
    url = _endpoint(endpoint) + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=15) as resp:
        data = json.load(resp)
    calls = data.get("calls")
    if not isinstance(calls, list):
        raise AssertionError("GET /_awsl/calls missing calls array")
    return [c for c in calls if isinstance(c, dict)]


def clear_calls(*, endpoint: str | None = None) -> None:
    req = urllib.request.Request(_endpoint(endpoint), method="DELETE")
    with urllib.request.urlopen(req, timeout=15) as resp:
        resp.read()


def assert_no_calls(
    workload: str,
    action_pattern: str,
    *,
    endpoint: str | None = None,
    since: str | float | None = None,
) -> None:
    """Assert workload made no calls matching action_pattern (fnmatch)."""
    calls = fetch_calls(workload=workload, endpoint=endpoint, since=since)
    hits = [c for c in calls if fnmatch.fnmatch(str(c.get("action", "")), action_pattern)]
    if hits:
        sample = ", ".join(str(c.get("action")) for c in hits[:5])
        raise AssertionError(
            f"workload {workload!r} made {len(hits)} call(s) matching "
            f"{action_pattern!r}: {sample}"
        )


def assert_exactly(
    workload: str,
    actions: list[str],
    *,
    endpoint: str | None = None,
    since: str | float | None = None,
) -> None:
    """Assert workload's chronological actions equal ``actions``."""
    calls = list(
        reversed(fetch_calls(workload=workload, endpoint=endpoint, since=since))
    )
    got = [str(c.get("action", "")) for c in calls]
    if got != actions:
        raise AssertionError(f"workload {workload!r} actions {got!r} != {actions!r}")


def assert_denied(
    workload: str,
    action: str,
    *,
    endpoint: str | None = None,
    since: str | float | None = None,
) -> dict[str, Any]:
    """Assert at least one denied call for action; return the newest match."""
    calls = fetch_calls(
        workload=workload,
        action=action,
        result="denied",
        endpoint=endpoint,
        since=since,
    )
    if not calls:
        raise AssertionError(f"no denied {action!r} for workload {workload!r}")
    reason = calls[0].get("reason")
    if not reason:
        raise AssertionError(f"denied {action!r} missing reason for {workload!r}")
    return calls[0]
