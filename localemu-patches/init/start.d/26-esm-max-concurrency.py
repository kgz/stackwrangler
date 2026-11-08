"""Enforce ScalingConfig.MaximumConcurrency at SQS ESM poll/invoke time (#453/#499).

LocalEmu stores MaximumConcurrency on the mapping and refuses create when < 2,
but the SQS poller processed batches serially and never capped concurrency.
Real AWS stops reading further SQS messages once concurrent invokes for that
mapping hit MaximumConcurrency; reserved concurrency on the function is a
separate limit — the lower of the two wins for in-flight ESM invocations.

When MaximumConcurrency is set, this patch dispatches up to that many concurrent
ReceiveMessage→invoke pipelines (BatchSize batches) and caps them at
min(MaximumConcurrency, ReservedConcurrentExecutions) when reserved is set.
Mappings without ScalingConfig keep the stock serial poller.

FIFO (#499): concurrent batch dispatch must not reorder a MessageGroupId.
Receive up to `limit` batches, merge by MessageGroupId (preserving receive order),
then run at most one invoke per group with up to `limit` groups in parallel —
matching AWS (concurrency capped by min(MC, active groups); in-group order held).
"""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor, as_completed

LOG = logging.getLogger("localemu.awsbox.esm_max_concurrency")


def _scaling_maximum_concurrency(esm_config) -> int | None:
    scaling = esm_config.get("ScalingConfig") if esm_config else None
    if not scaling:
        return None
    if isinstance(scaling, dict):
        raw = scaling.get("MaximumConcurrency")
    else:
        raw = getattr(scaling, "MaximumConcurrency", None)
        if raw is None and callable(getattr(scaling, "get", None)):
            raw = scaling.get("MaximumConcurrency")
    if raw is None:
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _reserved_concurrency(function_arn: str) -> int | None:
    from localemu.services.lambda_.api_utils import function_locators_from_arn
    from localemu.services.lambda_.invocation.models import lambda_stores

    try:
        function_name, _qualifier, account_id, region = function_locators_from_arn(function_arn)
        fn = lambda_stores[account_id][region].functions.get(function_name)
    except Exception as e:
        LOG.debug("ESM max-concurrency reserved lookup failed: %s", e)
        return None
    if fn is None:
        return None
    reserved = getattr(fn, "reserved_concurrent_executions", None)
    if reserved is None:
        return None
    try:
        return int(reserved)
    except (TypeError, ValueError):
        return None


def _live_esm_config(worker) -> dict:
    lock = getattr(worker, "_state_lock", None)
    state = getattr(worker, "_state", None)
    if lock is None or state is None:
        return worker.esm_config
    with lock:
        live = state.event_source_mappings.get(worker.uuid)
    if live is None:
        return worker.esm_config
    return live


def _effective_limit(worker) -> int | None:
    """Return concurrent invoke cap, or None to keep serial stock behaviour."""
    cfg = _live_esm_config(worker)
    max_conc = _scaling_maximum_concurrency(cfg)
    if max_conc is None:
        max_conc = _scaling_maximum_concurrency(worker.esm_config)
    if max_conc is None:
        return None

    # Keep worker copy in sync so describe-style reads see ScalingConfig.
    scaling = cfg.get("ScalingConfig") if isinstance(cfg, dict) else None
    if scaling is not None:
        worker.esm_config["ScalingConfig"] = scaling

    function_arn = worker.esm_config.get("FunctionArn") or cfg.get("FunctionArn")
    reserved = None
    if isinstance(function_arn, str) and function_arn:
        reserved = _reserved_concurrency(function_arn)

    if reserved is None:
        return max(1, max_conc)
    return max(0, min(max_conc, reserved))


def _receive_batch(poller, *, long_poll: bool) -> list:
    from localemu.aws.api.sqs import MessageSystemAttributeName
    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )
    from localemu.services.lambda_.event_source_mapping.pollers.sqs_poller import (
        DEFAULT_MAX_RECEIVE_COUNT,
        DEFAULT_MAX_WAIT_TIME_SECONDS,
    )

    wait = (
        min(poller.maximum_batching_window, DEFAULT_MAX_WAIT_TIME_SECONDS)
        if long_poll
        else 0
    )
    response = poller.source_client.receive_message(
        QueueUrl=poller.queue_url,
        MaxNumberOfMessages=min(poller.batch_size, DEFAULT_MAX_RECEIVE_COUNT),
        WaitTimeSeconds=wait,
        MessageAttributeNames=["All"],
        MessageSystemAttributeNames=[MessageSystemAttributeName.All],
        sqs_override_max_message_count=poller.batch_size,
        sqs_override_wait_time_seconds=wait if long_poll else 0,
    )
    messages = response.get("Messages", [])
    if not messages:
        raise EmptyPollResultsException(service="sqs", source_arn=poller.source_arn)
    return messages


def _await_futures(futures, *, uuid: str, kind: str) -> None:
    errors: list[BaseException] = []
    for fut in as_completed(futures):
        try:
            fut.result()
        except Exception as e:
            errors.append(e)
            LOG.warning(
                "ESM max-concurrency %s failed uuid=%s: %s",
                kind,
                uuid,
                e,
                exc_info=LOG.isEnabledFor(logging.DEBUG),
            )
    if errors:
        raise errors[0]


def _receive_up_to(poller, limit: int) -> list:
    """Long-poll once, then short-poll up to limit-1 more non-empty batches."""
    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )

    messages: list = []
    try:
        messages.extend(_receive_batch(poller, long_poll=True))
    except EmptyPollResultsException:
        raise
    for _ in range(max(0, limit - 1)):
        try:
            messages.extend(_receive_batch(poller, long_poll=False))
        except EmptyPollResultsException:
            break
    return messages


def _poll_fifo_with_max_concurrency(poller, worker, limit: int) -> None:
    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )
    from localemu.services.lambda_.event_source_mapping.pollers.sqs_poller import (
        split_by_message_group_id,
    )

    if limit <= 0:
        raise EmptyPollResultsException(service="sqs", source_arn=poller.source_arn)

    messages = _receive_up_to(poller, limit)
    groups = split_by_message_group_id(messages)
    LOG.debug(
        "ESM FIFO max-concurrency uuid=%s groups=%d msgs=%d limit=%d",
        worker.uuid,
        len(groups),
        len(messages),
        limit,
    )
    with ThreadPoolExecutor(
        max_workers=limit, thread_name_prefix=f"esm-fifo-mc-{worker.uuid[:8]}"
    ) as pool:
        futures = [
            pool.submit(poller.handle_messages, group_messages)
            for group_messages in groups.values()
        ]
        _await_futures(futures, uuid=worker.uuid, kind="fifo-group")


def _poll_standard_with_max_concurrency(poller, worker, limit: int) -> None:
    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )

    if limit <= 0:
        # Reserved=0 (or equivalent): do not consume; leave messages on the queue.
        raise EmptyPollResultsException(service="sqs", source_arn=poller.source_arn)

    futures = []
    received_any = False
    with ThreadPoolExecutor(
        max_workers=limit, thread_name_prefix=f"esm-mc-{worker.uuid[:8]}"
    ) as pool:
        for i in range(limit):
            try:
                messages = _receive_batch(poller, long_poll=(i == 0 and not received_any))
            except EmptyPollResultsException:
                if not received_any:
                    raise
                break
            received_any = True
            LOG.debug(
                "ESM max-concurrency dispatch uuid=%s batch=%d/%d msgs=%d",
                worker.uuid,
                i + 1,
                limit,
                len(messages),
            )
            futures.append(pool.submit(poller.handle_messages, messages))

        _await_futures(futures, uuid=worker.uuid, kind="batch")


def _poll_with_max_concurrency(poller, worker, limit: int) -> None:
    if getattr(poller, "is_fifo_queue", False):
        return _poll_fifo_with_max_concurrency(poller, worker, limit)
    return _poll_standard_with_max_concurrency(poller, worker, limit)


def _wrap_worker_poll(worker) -> None:
    poller = getattr(worker, "poller", None)
    if poller is None or getattr(poller, "_awsbox_esm_max_conc", False):
        return

    source_arn = worker.esm_config.get("EventSourceArn") or ""
    if ":sqs:" not in source_arn:
        poller._awsbox_esm_max_conc = True
        return

    original_poll = poller.poll_events

    def poll_events():
        limit = _effective_limit(worker)
        if limit is None:
            return original_poll()
        return _poll_with_max_concurrency(poller, worker, limit)

    poller.poll_events = poll_events
    poller._awsbox_esm_max_conc = True


def _patch_runtime_poll() -> None:
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmWorker

    if getattr(EsmWorker, "_awsbox_esm_max_conc", False):
        return

    original_loop = EsmWorker.poller_loop

    def poller_loop(self, *args, **kwargs):
        _wrap_worker_poll(self)
        return original_loop(self, *args, **kwargs)

    EsmWorker.poller_loop = poller_loop
    EsmWorker._awsbox_esm_max_conc = True


def _patch() -> None:
    _patch_runtime_poll()
    LOG.info("awsbox ESM ScalingConfig.MaximumConcurrency poll cap applied")


_patch()
