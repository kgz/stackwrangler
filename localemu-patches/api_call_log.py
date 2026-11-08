"""Per-workload AWS API call log (CloudTrail-lite, #194).

Records time, caller, workload id, service, action, resource ARNs, result,
and request id. No request/response bodies — resource identifiers only.
"""

from __future__ import annotations

import fnmatch
import json
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any
from urllib.parse import parse_qs

LOG_MAX = 10_000


@dataclass
class CallRecord:
    time: str
    caller: str
    workload: str
    service: str
    action: str
    resources: list[str] = field(default_factory=list)
    result: str = "allowed"  # allowed | denied
    reason: str | None = None
    request_id: str | None = None
    epoch: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d.pop("epoch", None)
        return d


_lock = threading.RLock()
_calls: deque[CallRecord] = deque(maxlen=LOG_MAX)


def clear() -> None:
    with _lock:
        _calls.clear()


def record(
    *,
    caller: str,
    workload: str,
    service: str,
    action: str,
    resources: list[str] | None = None,
    result: str = "allowed",
    reason: str | None = None,
    request_id: str | None = None,
    when: float | None = None,
) -> CallRecord:
    epoch = when if when is not None else time.time()
    rec = CallRecord(
        time=datetime.fromtimestamp(epoch, tz=timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        caller=caller,
        workload=workload,
        service=service,
        action=action,
        resources=[r for r in (resources or []) if r],
        result=result,
        reason=reason,
        request_id=request_id,
        epoch=epoch,
    )
    with _lock:
        _calls.append(rec)
    return rec


def query(
    *,
    workload: str | None = None,
    service: str | None = None,
    action: str | None = None,
    result: str | None = None,
    since: str | float | None = None,
    limit: int = 500,
) -> list[CallRecord]:
    since_epoch = _parse_since(since)
    with _lock:
        items = list(_calls)
    out: list[CallRecord] = []
    for rec in reversed(items):
        if workload and not _workload_match(rec.workload, workload):
            continue
        if service and rec.service != service and not rec.action.startswith(f"{service}:"):
            continue
        if action and not fnmatch.fnmatch(rec.action, action):
            continue
        if result and rec.result != result:
            continue
        if since_epoch is not None and rec.epoch < since_epoch:
            continue
        out.append(rec)
        if len(out) >= max(1, limit):
            break
    return out


def assert_no_calls(
    workload: str,
    action_pattern: str,
    *,
    since: str | float | None = None,
) -> None:
    """Raise AssertionError if workload made any call matching action_pattern."""
    hits = query(workload=workload, action=action_pattern, since=since)
    if hits:
        sample = ", ".join(h.action for h in hits[:5])
        raise AssertionError(
            f"workload {workload!r} made {len(hits)} call(s) matching "
            f"{action_pattern!r}: {sample}"
        )


def assert_calls(
    workload: str,
    action: str,
    *,
    count: int | None = None,
    exactly: list[str] | None = None,
    since: str | float | None = None,
    result: str | None = None,
) -> list[CallRecord]:
    """Assert calls for a workload.

    - count: exact number of matching ``action`` (fnmatch) calls
    - exactly: when set, the workload's actions (in order, newest-last in
      storage / chronological) must equal this list; typically used with a
      fresh ``clear()`` before the workload runs
    """
    if exactly is not None:
        all_recs = list(reversed(query(workload=workload, since=since, limit=LOG_MAX)))
        got = [r.action for r in all_recs]
        if got != exactly:
            raise AssertionError(
                f"workload {workload!r} actions {got!r} != expected {exactly!r}"
            )
        return all_recs

    hits = query(workload=workload, action=action, since=since, result=result, limit=LOG_MAX)
    if count is not None and len(hits) != count:
        raise AssertionError(
            f"workload {workload!r} expected {count} {action!r} call(s), got {len(hits)}"
        )
    return hits


def _workload_match(value: str, pattern: str) -> bool:
    if "*" in pattern or "?" in pattern:
        return fnmatch.fnmatch(value, pattern)
    return value == pattern


def _parse_since(since: str | float | None) -> float | None:
    if since is None or since == "":
        return None
    if isinstance(since, (int, float)):
        return float(since)
    text = str(since).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return float(text)
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def workload_id_for_caller(caller: Any) -> str:
    principal_type = getattr(caller, "principal_type", None) or ""
    session_name = getattr(caller, "session_name", None)
    username = getattr(caller, "username", None)
    role_name = getattr(caller, "role_name", None)
    arn = getattr(caller, "arn", "") or ""

    if principal_type == "AssumedRole" and session_name:
        return str(session_name)
    if principal_type == "User" and username:
        return f"user/{username}"
    if principal_type == "Root":
        return "root"
    if role_name and session_name:
        return str(session_name)
    if username:
        return f"user/{username}"
    return arn or "unknown"


def calls_to_json(records: list[CallRecord]) -> str:
    return json.dumps({"calls": [r.to_dict() for r in records]}, indent=2)


def parse_query_params(query_string: str) -> dict[str, str]:
    raw = parse_qs(query_string or "", keep_blank_values=False)
    return {k: (v[0] if v else "") for k, v in raw.items()}
