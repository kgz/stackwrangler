"""Keep ESMs of failed functions after PERSISTENCE load; drop true orphans (#717, #836).

ListEventSourceMappings reads the Lambda store. Delete requires a live
``esm_workers`` entry bound into the Skeleton dispatch table at provider
init — class-level monkeypatches never reach that bound method.

After recreate, deferred restore often fails (missing function/poller) but
leaves the mapping in the store. List still shows it; delete raises
ResourceNotFoundException; Create hits ResourceConflictException.

1. Patch the live DeleteEventSourceMapping dispatcher to remove store-only
   orphans without a poller.
2. Wrap the provider's ``_run_deferred_restore`` (instance attr, before the
   deferred thread finishes waiting on S3) to drop unrestored mappings once
   restore finishes.
3. ``on_infra_ready`` sweeps only after restore completion (gateway ready ≠
   restore complete; ESM workers exist only after function restore). If
   restore already finished before the wrap was installed, mark complete and
   sweep at install time — never mid-restore.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.esm_persist_orphans")

_RESTORE_COMPLETE_ATTR = "_awsbox_esm_persist_restore_complete"


def _lambda_provider():
    from localemu.services.plugins import SERVICE_PLUGINS

    service = SERVICE_PLUGINS.get_service("lambda")
    if service is None:
        return None
    return getattr(service, "_provider", None)


def _drop_esm_from_stores(uuid: str) -> bool:
    if not uuid:
        return False
    from localemu.services.lambda_.invocation.models import lambda_stores

    dropped = False
    for account_bundle in lambda_stores.values():
        for state in account_bundle.values():
            mappings = getattr(state, "event_source_mappings", None)
            if mappings is not None and uuid in mappings:
                mappings.pop(uuid, None)
                dropped = True
    return dropped


def _any_pending_function_versions() -> bool:
    """True while Phase-1 left versions Pending and Phase-2 has not finished."""
    from localemu.aws.api.lambda_ import State
    from localemu.services.lambda_.invocation.models import lambda_stores

    for account_bundle in lambda_stores.values():
        for state in account_bundle.values():
            for fn in getattr(state, "functions", {}).values():
                for fn_version in getattr(fn, "versions", {}).values():
                    version_state = getattr(
                        getattr(fn_version, "config", None), "state", None
                    )
                    if version_state is not None and version_state.state == State.Pending:
                        return True
    return False


def _mark_restore_complete(provider) -> None:
    setattr(provider, _RESTORE_COMPLETE_ATTR, True)


def _restore_complete(provider) -> bool:
    return bool(getattr(provider, _RESTORE_COMPLETE_ATTR, False))


def _function_version(function_arn):
    """The mapped FunctionVersion, or None when the function is gone."""
    from localemu.aws.api.lambda_ import ResourceNotFoundException
    from localemu.services.lambda_.provider_utils import get_function_version_from_arn

    if not function_arn:
        return None
    try:
        return get_function_version_from_arn(function_arn)
    except ResourceNotFoundException:
        return None


def _sweep_orphan_esms(provider) -> int:
    """Drop mappings whose function no longer exists (#717).

    A mapping whose function exists but failed to start keeps its record, as on
    AWS; the reconcile loop starts its poller once the function is Active (#836).
    """
    if provider is None:
        return 0
    from localemu.services.lambda_.invocation.models import lambda_stores

    workers = getattr(provider, "esm_workers", None) or {}
    dropped = 0
    for account_bundle in lambda_stores.values():
        for state in account_bundle.values():
            mappings = getattr(state, "event_source_mappings", None)
            if not mappings:
                continue
            for uuid, esm in list(mappings.items()):
                if uuid in workers:
                    continue
                function_arn = esm.get("FunctionArn")
                if _function_version(function_arn) is not None:
                    LOG.warning(
                        "ESM %s kept without a poller (function %s not running yet)",
                        uuid,
                        function_arn,
                    )
                    continue
                mappings.pop(uuid, None)
                dropped += 1
                LOG.warning(
                    "Dropped orphan ESM %s (function %s no longer exists)",
                    uuid,
                    function_arn,
                )
    return dropped


def _start_waiting_pollers(provider) -> int:
    """Start pollers for kept mappings whose function is Active again (#836)."""
    from localemu.aws.api.lambda_ import State
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmState
    from localemu.services.lambda_.event_source_mapping.esm_worker_factory import (
        EsmWorkerFactory,
    )
    from localemu.services.lambda_.invocation.models import lambda_stores

    workers = getattr(provider, "esm_workers", None)
    if workers is None:
        return 0
    started = 0
    for account_bundle in lambda_stores.values():
        for state in account_bundle.values():
            mappings = getattr(state, "event_source_mappings", None) or {}
            for uuid, esm in list(mappings.items()):
                if uuid in workers or esm.get("State") in (EsmState.DELETING,):
                    continue
                version = _function_version(esm.get("FunctionArn"))
                if version is None or version.config.state.state != State.Active:
                    continue
                enabled = esm.get("State", EsmState.DISABLED) not in (
                    EsmState.DISABLED,
                    EsmState.DISABLING,
                )
                worker = EsmWorkerFactory(esm, version.config.role, enabled).get_esm_worker()
                # Claim the slot before starting, so a lost race never leaves a
                # second poller running; re-check the record in case of a delete.
                if workers.setdefault(uuid, worker) is not worker:
                    continue
                if mappings.get(uuid) is not esm:
                    workers.pop(uuid, None)
                    continue
                try:
                    worker.create()
                except Exception:
                    workers.pop(uuid, None)
                    LOG.debug("ESM %s poller start failed; retrying", uuid, exc_info=True)
                    continue
                started += 1
                LOG.info("Started poller for kept ESM %s (#836)", uuid)
    return started


_RECONCILE_INTERVAL_S = 5


def _install_reconcile_loop(provider) -> None:
    # ponytail: fixed-interval scan of workerless mappings; hook function
    # state changes instead if many mappings make the scan costly.
    import threading
    import time

    if getattr(provider, "_awsbox_esm_reconcile_started", False):
        return
    provider._awsbox_esm_reconcile_started = True

    def _loop():
        while True:
            time.sleep(_RECONCILE_INTERVAL_S)
            if not _restore_complete(provider):
                continue
            try:
                _start_waiting_pollers(provider)
            except Exception:
                LOG.debug("ESM reconcile pass failed", exc_info=True)

    threading.Thread(target=_loop, name="esm-reconcile", daemon=True).start()


def _sweep_after_restore(provider, reason: str) -> None:
    n = _sweep_orphan_esms(provider)
    if n:
        LOG.info(
            "awsbox ESM persist %s: dropped %d orphan mapping(s) (#717)",
            reason,
            n,
        )


def _delete_orphan_or_delegate(provider, original_fn, context, uuid, **kwargs):
    from localemu.aws.api.lambda_ import ResourceNotFoundException
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmState
    from localemu.services.lambda_.invocation.models import lambda_stores

    state = lambda_stores[context.account_id][context.region]
    event_source_mapping = state.event_source_mappings.get(uuid)
    if not event_source_mapping:
        raise ResourceNotFoundException(
            "The resource you requested does not exist.", Type="User"
        )
    workers = getattr(provider, "esm_workers", None) or {}
    if uuid not in workers:
        arn = event_source_mapping.get("EventSourceMappingArn")
        if arn:
            provider._remove_all_tags(arn)
        state.event_source_mappings.pop(uuid, None)
        LOG.info("Deleted orphan ESM %s (no live poller)", uuid)
        return {**dict(event_source_mapping), "State": EsmState.DELETING}
    return original_fn(context, uuid=uuid, **kwargs)


def _patch_delete_dispatcher(provider) -> bool:
    from localemu.services.plugins import SERVICE_PLUGINS

    service = SERVICE_PLUGINS.get_service("lambda")
    if service is None or service.skeleton is None:
        return False
    table = getattr(service.skeleton, "dispatch_table", None) or {}
    dispatcher = table.get("DeleteEventSourceMapping")
    if dispatcher is None or getattr(dispatcher, "_awsbox_esm_persist_orphans", False):
        return dispatcher is not None and getattr(
            dispatcher, "_awsbox_esm_persist_orphans", False
        )

    original_fn = dispatcher.fn

    def delete_fn(context, uuid=None, **kwargs):
        # expand_parameters path uses kwargs; keep both shapes safe.
        resolved = uuid if uuid is not None else kwargs.get("uuid")
        return _delete_orphan_or_delegate(
            provider, original_fn, context, resolved, **kwargs
        )

    dispatcher.fn = delete_fn
    dispatcher._awsbox_esm_persist_orphans = True
    return True


def _patch_deferred_restore(provider) -> bool:
    if provider is None:
        return False
    if getattr(provider, "_awsbox_esm_persist_orphans_restore", False):
        return True

    original = provider._run_deferred_restore

    def _run_deferred_restore(pending_functions, pending_esms) -> None:
        try:
            original(pending_functions, pending_esms)
        finally:
            _mark_restore_complete(provider)
            _sweep_after_restore(provider, "post-restore")

    provider._run_deferred_restore = _run_deferred_restore
    provider._awsbox_esm_persist_orphans_restore = True

    # Restore finished before this wrap (or never scheduled): no Pending left.
    # Mid-restore still has Pending versions — leave the flag clear so ready
    # does not sweep until the wrapped Phase-2 finally runs.
    if not _any_pending_function_versions():
        _mark_restore_complete(provider)
        _sweep_after_restore(provider, "install-catchup")

    return True


def _install_ready_sweep() -> None:
    from localemu.runtime import hooks

    if getattr(_install_ready_sweep, "_installed", False):
        return

    @hooks.on_infra_ready()
    def _sweep_after_ready():
        provider = _lambda_provider()
        if provider is None:
            return
        if not _restore_complete(provider):
            LOG.debug(
                "awsbox ESM persist ready-sweep: skip; deferred restore still in progress"
            )
            return
        _sweep_after_restore(provider, "ready-sweep")

    _install_ready_sweep._installed = True


def _install() -> None:
    provider = _lambda_provider()
    if provider is None:
        LOG.warning("awsbox ESM persist orphans: lambda provider not ready yet")
        return

    deleted = _patch_delete_dispatcher(provider)
    restored = _patch_deferred_restore(provider)
    _install_ready_sweep()
    _install_reconcile_loop(provider)
    LOG.info(
        "awsbox ESM persist orphan cleanup applied (#717/#836) delete=%s restore=%s",
        deleted,
        restored,
    )


_install()
