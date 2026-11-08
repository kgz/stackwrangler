"""CFN Fn::ImportValue: missing export → AWS-shaped error (#652).

Upstream returns Nothing when the export is absent. Nested under Fn::Sub that
drops the map entry, so CreateChangeSet reports Unresolved resource
dependencies [SubVar] instead of the missing export. Direct property use then
fails later as Missing required parameter.

Raise ValidationError("No export named <name> found") like AWS.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.cfn_missing_export")


def _patch() -> None:
    from localemu.services.cloudformation.engine.v2.change_set_model import (
        NodeIntrinsicFunction,
        is_nothing,
    )
    from localemu.services.cloudformation.engine.v2.change_set_model_describer import (
        CHANGESET_KNOWN_AFTER_APPLY,
        ChangeSetModelDescriber,
    )
    from localemu.services.cloudformation.engine.v2.change_set_model_preproc import (
        ChangeSetModelPreproc,
        PreprocEntityDelta,
    )
    from localemu.services.cloudformation.engine.validations import ValidationError
    from localemu.services.cloudformation.stores import exports_map

    def visit_import_value(
        self: ChangeSetModelPreproc,
        node_intrinsic_function: NodeIntrinsicFunction,
    ) -> PreprocEntityDelta:
        def _compute_fn_import_value(string):
            if not isinstance(string, str):
                raise RuntimeError(f"Invalid parameter for import: '{string}'")

            exports = exports_map(
                account_id=self._change_set.account_id,
                region_name=self._change_set.region_name,
            )
            value = exports.get(string, {}).get("Value")
            if value is None or is_nothing(value):
                raise ValidationError(f"No export named {string} found")
            return value

        arguments_delta = self.visit(node_intrinsic_function.arguments)
        return self._cached_apply(
            scope=node_intrinsic_function.scope,
            arguments_delta=arguments_delta,
            resolver=_compute_fn_import_value,
        )

    def visit_import_value_describer(
        self: ChangeSetModelDescriber,
        node_intrinsic_function: NodeIntrinsicFunction,
    ) -> PreprocEntityDelta:
        try:
            return visit_import_value(self, node_intrinsic_function)
        except ValidationError as e:
            if not self._include_property_values:
                raise
            message = e.message or str(e)
            if "No export named" not in message:
                raise
            resource_name = node_intrinsic_function.scope.split("/")[2]
            export_name = node_intrinsic_function.arguments.value
            self._change_set.status_reason = (
                "[WARN] --include-property-values option can return incomplete "
                f"ChangeSet data because: ChangeSet creation failed for resource "
                f"[{resource_name}] because: No export named {export_name}"
            )
            return PreprocEntityDelta(after=CHANGESET_KNOWN_AFTER_APPLY)

    ChangeSetModelPreproc.visit_node_intrinsic_function_fn_import_value = (
        visit_import_value
    )
    ChangeSetModelDescriber.visit_node_intrinsic_function_fn_import_value = (
        visit_import_value_describer
    )
    LOG.info("cfn missing-export: Fn::ImportValue raises No export named … found")


_patch()
