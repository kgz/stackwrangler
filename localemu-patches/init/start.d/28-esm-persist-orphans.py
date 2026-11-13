"""Drop unrestorable ESMs after PERSISTENCE load; delete listed orphans (#717).

ListEventSourceMappings reads the Lambda store. Delete requires a live
``esm_workers`` entry bound into the Skeleton dispatch table at provider
init — class-level monkeypatches never reach that bound method.

After recreate, deferred restore often fails (missing function/poller) but
leaves the mapping in the store. List still shows it; delete raises
ResourceNotFoundException; Create hits ResourceConflictException.

1. Patch the live DeleteEventSourceMapping dispatcher to remove store-only
   orphans without a poller.
2. Wrap the provider's ``_run_deferred_restore`` (instance attr, before the
   deferred thread finishes waiting on S3) to drop unrestored mappings.
3. ``on_infra_ready`` sweeps again in case restore finished first.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.esm_persist_orphans")


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


def _sweep_orphan_esms(provider) -> int:
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
            for uuid in list(mappings.keys()):
                if uuid in workers:
                    continue
                mappings.pop(uuid, None)
                dropped += 1
                LOG.warning(
                    "Dropped unrestored ESM %s (function/poller not restored)",
                    uuid,
                )
    return dropped


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
        original(pending_functions, pending_esms)
        n = _sweep_orphan_esms(provider)
        if n:
            LOG.info("awsbox ESM persist: dropped %d orphan mapping(s) (#717)", n)

    provider._run_deferred_restore = _run_deferred_restore
    provider._awsbox_esm_persist_orphans_restore = True
    return True


def _install_ready_sweep() -> None:
    from localemu.runtime import hooks

    if getattr(_install_ready_sweep, "_installed", False):
        return

    @hooks.on_infra_ready()
    def _sweep_after_ready():
        provider = _lambda_provider()
        n = _sweep_orphan_esms(provider)
        if n:
            LOG.info(
                "awsbox ESM persist ready-sweep: dropped %d orphan mapping(s) (#717)",
                n,
            )

    _install_ready_sweep._installed = True


def _install() -> None:
    provider = _lambda_provider()
    if provider is None:
        LOG.warning("awsbox ESM persist orphans: lambda provider not ready yet")
        return

    deleted = _patch_delete_dispatcher(provider)
    restored = _patch_deferred_restore(provider)
    _install_ready_sweep()
    LOG.info(
        "awsbox ESM persist orphan cleanup applied (#717) delete=%s restore=%s",
        deleted,
        restored,
    )


_install()
