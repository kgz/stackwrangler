"""Persist security-group rule Description on prefix-list rules (#682).

Moto's ``SecurityGroupRule.description`` only reads ``ip_range``, and
``_iterate_security_rules`` drops ``Description`` from ``PrefixListIds``
entries when minting rules. Terraform ``aws_vpc_security_group_egress_rule``
with ``prefix_list_id`` + ``description`` then perpetual-diffs on plan.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.sg_prefixlist_description")


def _patch() -> None:
    from moto.ec2.models.security_groups import (
        GroupedSecurityRuleView,
        SecurityGroup,
        SecurityGroupBackend,
        SecurityGroupRule,
    )

    if getattr(SecurityGroupRule, "_awsbox_prefixlist_description", False):
        return

    _orig_init = SecurityGroupRule.__init__

    def __init__(
        self,
        ec2_backend,
        ip_protocol,
        group_id,
        from_port,
        to_port,
        ip_range,
        source_group=None,
        prefix_list_id=None,
        is_egress=True,
        tags=None,
    ):
        pl_desc = None
        if isinstance(prefix_list_id, dict):
            pl_desc = prefix_list_id.get("Description")
        _orig_init(
            self,
            ec2_backend,
            ip_protocol,
            group_id,
            from_port,
            to_port,
            ip_range,
            source_group=source_group,
            prefix_list_id=prefix_list_id,
            is_egress=is_egress,
            tags=tags,
        )
        self._prefix_list_description = pl_desc

    @property
    def description(self):
        if self.ip_range and "Description" in self.ip_range:
            return self.ip_range.get("Description")
        if self.source_group and "Description" in self.source_group:
            return self.source_group.get("Description")
        return getattr(self, "_prefix_list_description", None)

    def _flattened_rules(self, rules):
        rules_to_return: list = []
        for rule in rules:
            for already_added in rules_to_return:
                if (
                    already_added.from_port == rule.from_port
                    and already_added.to_port == rule.to_port
                    and already_added.ip_protocol == rule.ip_protocol
                ):
                    if rule.ip_range:
                        already_added.all_ip_ranges.append(rule.ip_range)
                    if rule.source_group:
                        already_added.source_groups.append(rule.source_group)
                    if rule.prefix_list_id:
                        entry = {"PrefixListId": rule.prefix_list_id}
                        if rule.description:
                            entry["Description"] = rule.description
                        already_added.prefix_list_ids.append(entry)
                    break
            else:
                view = GroupedSecurityRuleView(
                    rule.from_port, rule.to_port, rule.ip_protocol
                )
                if rule.ip_range:
                    view.all_ip_ranges.append(rule.ip_range)
                if rule.source_group:
                    view.source_groups.append(rule.source_group)
                if rule.prefix_list_id:
                    entry = {"PrefixListId": rule.prefix_list_id}
                    if rule.description:
                        entry["Description"] = rule.description
                    view.prefix_list_ids.append(entry)
                rules_to_return.append(view)
        return rules_to_return

    _orig_update = SecurityGroupBackend._sg_update_description

    def _sg_update_description(self, security_rule, rule):
        _orig_update(self, security_rule, rule)
        if rule.prefix_list_id and security_rule.description is not None:
            rule._prefix_list_description = security_rule.description

    SecurityGroupRule.__init__ = __init__
    SecurityGroupRule.description = description
    SecurityGroupRule._awsbox_prefixlist_description = True
    SecurityGroup._flattened_rules = _flattened_rules
    SecurityGroupBackend._sg_update_description = _sg_update_description
    LOG.info("awsbox SG prefix-list rule Description patch applied")


_patch()
