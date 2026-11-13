"""Drop unrestorable ESMs after PERSISTENCE load; delete listed orphans (#717).

ListEventSourceMappings reads the Lambda store. Delete/Get require a live
``esm_workers`` entry. After recreate, deferred restore often fails (missing
function / poller) but leaves the mapping in the store — list still shows it,
delete raises ResourceNotFoundException, and CreateEventSourceMapping hits
ResourceConflictException ("already exists").

1. After deferred restore, drop mappings still in the store without a worker.
2. DeleteEventSourceMapping removes a store-only orphan without a worker.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.esm_persist_orphans")


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


def _patch_delete() -> None:
    from localemu.aws.api.lambda_ import ResourceNotFoundException
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmState
    from localemu.services.lambda_.invocation.models import lambda_stores
    from localemu.services.lambda_.provider import LambdaProvider

    if getattr(LambdaProvider.delete_event_source_mapping, "_awsbox_esm_persist_orphans", False):
        return

    original = LambdaProvider.delete_event_source_mapping

    def delete_event_source_mapping(self, context, uuid, **kwargs):
        state = lambda_stores[context.account_id][context.region]
        event_source_mapping = state.event_source_mappings.get(uuid)
        if not event_source_mapping:
            raise ResourceNotFoundException(
                "The resource you requested does not exist.", Type="User"
            )
        if uuid not in self.esm_workers:
            arn = event_source_mapping.get("EventSourceMappingArn")
            if arn:
                self._remove_all_tags(arn)
            state.event_source_mappings.pop(uuid, None)
            LOG.info("Deleted orphan ESM %s (no live poller)", uuid)
            return {**dict(event_source_mapping), "State": EsmState.DELETING}
        return original(self, context, uuid, **kwargs)

    delete_event_source_mapping._awsbox_esm_persist_orphans = True
    LambdaProvider.delete_event_source_mapping = delete_event_source_mapping


def _sweep_orphan_esms(provider, pending_esms) -> int:
    dropped = 0
    for esm in pending_esms:
        uuid = esm.get("UUID")
        if not uuid:
            continue
        if uuid in provider.esm_workers:
            continue
        if _drop_esm_from_stores(uuid):
            dropped += 1
            LOG.warning(
                "Dropped unrestored ESM %s (function/poller not restored)",
                uuid,
            )
    return dropped


def _patch_deferred_restore() -> None:
    from localemu.services.lambda_.provider import LambdaProvider

    if getattr(LambdaProvider._run_deferred_restore, "_awsbox_esm_persist_orphans", False):
        return

    original = LambdaProvider._run_deferred_restore

    def _run_deferred_restore(self, pending_functions, pending_esms) -> None:
        original(self, pending_functions, pending_esms)
        n = _sweep_orphan_esms(self, pending_esms)
        if n:
            LOG.info("awsbox ESM persist: dropped %d orphan mapping(s) (#717)", n)

    _run_deferred_restore._awsbox_esm_persist_orphans = True
    LambdaProvider._run_deferred_restore = _run_deferred_restore


def _install() -> None:
    _patch_delete()
    _patch_deferred_restore()
    LOG.info("awsbox ESM persist orphan cleanup applied (#717)")


_install()
