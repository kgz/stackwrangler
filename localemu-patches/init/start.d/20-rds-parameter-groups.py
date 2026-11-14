"""RDS DB / cluster parameter describe fields for Terraform (#710).

Moto stores only ParameterName / ParameterValue / ApplyMethod from
ModifyDBParameterGroup. Terraform's aws_db_parameter_group read keeps
parameters with Source == "user", so missing Source → perpetual
in-place update on every plan.
"""

from __future__ import annotations

import logging
from typing import Any, Iterable

LOG = logging.getLogger("localemu.awsbox.rds_parameter_groups")


def _apply_type_for(apply_method: object) -> str:
    method = str(apply_method or "").lower()
    if method == "pending-reboot":
        return "static"
    return "dynamic"


def _enrich_user_parameter(parameter: dict[str, Any]) -> None:
    """Mark a stored (user-modified) parameter the way AWS Describe does."""
    parameter.setdefault("Source", "user")
    parameter.setdefault("IsModifiable", True)
    if "ApplyType" not in parameter:
        parameter["ApplyType"] = _apply_type_for(parameter.get("ApplyMethod"))


def _normalize_parameters(
    parameters: Iterable[dict[str, Any]],
    source_filter: str | None,
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for raw in parameters:
        item = dict(raw)
        # Moto only persists modified params — treat missing Source as user.
        if item.get("Source") in (None, ""):
            item["Source"] = "user"
        _enrich_user_parameter(item)
        if source_filter and item.get("Source") != source_filter:
            continue
        out.append(item)
    return out


def _patch() -> None:
    from moto.core.responses import ActionResult
    from moto.rds.exceptions import DBParameterGroupNotFoundError
    from moto.rds.models import DBClusterParameterGroup, DBParameterGroup
    from moto.rds.responses import RDSResponse

    if getattr(DBParameterGroup, "_awsbox_param_source", False):
        return

    def update_parameters(self, new_parameters: Iterable[dict[str, Any]]) -> None:
        for new_parameter in new_parameters:
            name = new_parameter["ParameterName"]
            parameter = self.parameters[name]
            parameter.update(new_parameter)
            _enrich_user_parameter(parameter)

    def update_cluster_parameters(
        self, new_parameters: Iterable[dict[str, Any]]
    ) -> None:
        for new_parameter in new_parameters:
            name = new_parameter["ParameterName"]
            parameter = self.parameters[name]
            parameter.update(new_parameter)
            _enrich_user_parameter(parameter)

    def describe_db_parameters(self) -> ActionResult:
        db_parameter_group_name = self.params.get("DBParameterGroupName")
        db_parameter_groups = self.backend.describe_db_parameter_groups(
            {"db_parameter_group_name": db_parameter_group_name}
        )
        if not db_parameter_groups:
            raise DBParameterGroupNotFoundError(db_parameter_group_name)
        source = self.params.get("Source")
        parameters = _normalize_parameters(
            db_parameter_groups[0].parameters.values(),
            source if isinstance(source, str) else None,
        )
        return ActionResult({"Parameters": parameters})

    def describe_db_cluster_parameters(self) -> ActionResult:
        db_parameter_group_name = self.params.get("DBClusterParameterGroupName")
        db_parameter_groups = self.backend.describe_db_cluster_parameters(
            db_parameter_group_name
        )
        if db_parameter_groups is None:
            raise DBParameterGroupNotFoundError(db_parameter_group_name)
        source = self.params.get("Source")
        parameters = _normalize_parameters(
            db_parameter_groups,
            source if isinstance(source, str) else None,
        )
        return ActionResult({"Parameters": parameters})

    DBParameterGroup.update_parameters = update_parameters
    DBClusterParameterGroup.update_cluster_parameters = update_cluster_parameters
    DBParameterGroup._awsbox_param_source = True
    RDSResponse.describe_db_parameters = describe_db_parameters
    RDSResponse.describe_db_cluster_parameters = describe_db_cluster_parameters
    LOG.info("awsbox RDS parameter-group Source patch applied")


_patch()
