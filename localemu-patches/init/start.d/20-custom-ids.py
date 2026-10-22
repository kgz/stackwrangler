"""Honour `_custom_id_` on create, and map access keys to an account id.

Moto already routes `_custom_id_` through ``@moto_id`` for REST APIs and hosted
zones, but EC2 / ELBv2 / HTTP API / ECS never pass tags into that helper.
EC2 ids are minted by ``random_*`` in the model module that owns the create
method, so swapping that function for the duration of the call is enough.
"""

from __future__ import annotations

import logging
import re
import threading

LOG = logging.getLogger("localemu.awsbox.custom_ids")

TAG = "_custom_id_"
ZONE_CALLER_PREFIX = "_custom_id_:"

_HEX_8_OR_17 = r"[0-9a-f]{8}(?:[0-9a-f]{9})?"
_PATTERNS: dict[str, re.Pattern[str]] = {
    "vpc": re.compile(rf"^vpc-{_HEX_8_OR_17}$"),
    "subnet": re.compile(rf"^subnet-{_HEX_8_OR_17}$"),
    "security-group": re.compile(rf"^sg-{_HEX_8_OR_17}$"),
    "route-table": re.compile(rf"^rtb-{_HEX_8_OR_17}$"),
    "internet-gateway": re.compile(rf"^igw-{_HEX_8_OR_17}$"),
    "vpc-peering": re.compile(rf"^pcx-{_HEX_8_OR_17}$"),
    "instance": re.compile(rf"^i-{_HEX_8_OR_17}$"),
    "lb-suffix": re.compile(r"^[0-9a-f]{16}$"),
    "tg-suffix": re.compile(r"^[0-9a-f]{16}$"),
    "http-api": re.compile(r"^[a-z0-9]{10}$"),
    "hosted-zone": re.compile(r"^Z[A-Z0-9]{13,32}$"),
}
_ECS_ARN = re.compile(
    r"^arn:[a-z0-9-]+:ecs:[a-z0-9-]+:\d{12}:cluster/([A-Za-z0-9_-]+)$"
)

_swap_lock = threading.Lock()
_tls = threading.local()


def extract(tags: object) -> str | None:
    """Pull `_custom_id_` out of the shapes moto actually forwards.

    EC2 is inconsistent: VPC/route table/IGW pass a list of ``{Key,Value}``,
    security groups and peering pass a flat dict, subnets pass
    ``{resourceType: {key: value}}``, and Route53 XML may nest a single
    ``Tag`` dict.
    """
    if isinstance(tags, list):
        for item in tags:
            found = extract(item)
            if found:
                return found
        return None
    if not isinstance(tags, dict):
        return None
    key = tags.get("Key", tags.get("key"))
    if key == TAG:
        value = tags.get("Value", tags.get("value"))
        if isinstance(value, str) and value:
            return value
    raw = tags.get(TAG)
    if isinstance(raw, str) and raw:
        return raw
    for value in tags.values():
        if isinstance(value, (dict, list)):
            found = extract(value)
            if found:
                return found
    return None


def _find_tags(args: tuple[object, ...], kwargs: dict[str, object]) -> object:
    if "tags" in kwargs:
        return kwargs.get("tags")
    for arg in args:
        if extract(arg):
            return arg
    return None


def _invalid(service: str, custom_id: str, detail: str) -> None:
    message = (
        f"Value ({custom_id}) for parameter _custom_id_ is invalid. {detail}"
    )
    if service == "ec2":
        from moto.ec2.exceptions import EC2ClientError

        raise EC2ClientError("InvalidParameterValue", message)
    if service == "elbv2":
        from moto.elbv2.exceptions import ELBClientError

        raise ELBClientError("ValidationError", message)
    if service == "apigateway":
        from moto.apigateway.exceptions import BadRequestException

        raise BadRequestException(message)
    if service == "apigatewayv2":
        from moto.apigatewayv2.exceptions import BadRequestException

        raise BadRequestException(message)
    if service == "route53":
        from moto.route53.exceptions import InvalidInput

        raise InvalidInput(message)
    if service == "ecs":
        from moto.ecs.exceptions import ECSException

        raise ECSException("InvalidParameterException", message)
    from moto.core.exceptions import RESTError

    raise RESTError("InvalidParameterValue", message)


def _check(service: str, kind: str, custom_id: str) -> None:
    pattern = _PATTERNS[kind]
    if pattern.fullmatch(custom_id) is None:
        _invalid(service, custom_id, f"Expected {pattern.pattern}")


def _with_random(module: object, attr: str, custom_id: str, call):
    with _swap_lock:
        original = getattr(module, attr)
        state = {"used": False}

        def forced(*args: object, **kwargs: object) -> str:
            if not state["used"]:
                state["used"] = True
                return custom_id
            return original(*args, **kwargs)

        setattr(module, attr, forced)
        try:
            return call()
        finally:
            setattr(module, attr, original)


def _patch_ec2_create(
    cls: type,
    method: str,
    module: object,
    random_attr: str,
    kind: str,
    taken,
) -> None:
    if not hasattr(module, random_attr):
        LOG.error("custom id: missing %s.%s", module.__name__, random_attr)
        return
    original = getattr(cls, method)

    def wrapped(self, *args: object, **kwargs: object):
        custom_id = extract(_find_tags(args, kwargs))
        if not custom_id:
            return original(self, *args, **kwargs)
        _check("ec2", kind, custom_id)
        if taken(self, custom_id):
            _invalid("ec2", custom_id, "That id is already in use.")
        return _with_random(
            module, random_attr, custom_id, lambda: original(self, *args, **kwargs)
        )

    setattr(cls, method, wrapped)


def _sg_taken(self, custom_id: str) -> bool:
    groups = getattr(self, "groups", {})
    for vpc_groups in groups.values():
        if isinstance(vpc_groups, dict) and custom_id in vpc_groups:
            return True
    return False


def _instance_taken(self, custom_id: str) -> bool:
    for reservation in getattr(self, "reservations", {}).values():
        for instance in getattr(reservation, "instances", []):
            if getattr(instance, "id", None) == custom_id:
                return True
    return False


def _arn_suffix_taken(store: object, suffix: str) -> bool:
    if not isinstance(store, dict):
        return False
    needle = "/" + suffix
    return any(isinstance(arn, str) and arn.endswith(needle) for arn in store)


def _patch_ec2() -> None:
    import moto.ec2.models.instances as instances
    import moto.ec2.models.internet_gateways as igws
    import moto.ec2.models.route_tables as route_tables
    import moto.ec2.models.security_groups as security_groups
    import moto.ec2.models.subnets as subnets
    import moto.ec2.models.vpc_peering_connections as peering
    import moto.ec2.models.vpcs as vpcs

    _patch_ec2_create(
        vpcs.VPCBackend,
        "create_vpc",
        vpcs,
        "random_vpc_id",
        "vpc",
        lambda self, custom_id: custom_id in getattr(self, "vpcs", {}),
    )
    _patch_ec2_create(
        subnets.SubnetBackend,
        "create_subnet",
        subnets,
        "random_subnet_id",
        "subnet",
        lambda self, custom_id: custom_id in getattr(self, "subnets", {}),
    )
    _patch_ec2_create(
        security_groups.SecurityGroupBackend,
        "create_security_group",
        security_groups,
        "random_security_group_id",
        "security-group",
        _sg_taken,
    )
    _patch_ec2_create(
        route_tables.RouteBackend,
        "create_route_table",
        route_tables,
        "random_route_table_id",
        "route-table",
        lambda self, custom_id: custom_id in getattr(self, "route_tables", {}),
    )
    _patch_ec2_create(
        igws.InternetGatewayBackend,
        "create_internet_gateway",
        igws,
        "random_internet_gateway_id",
        "internet-gateway",
        lambda self, custom_id: custom_id in getattr(self, "internet_gateways", {}),
    )
    _patch_ec2_create(
        peering.VPCPeeringConnectionBackend,
        "create_vpc_peering_connection",
        peering,
        "random_vpc_peering_connection_id",
        "vpc-peering",
        lambda self, custom_id: custom_id in getattr(self, "vpc_pcxs", {}),
    )

    original_run = instances.InstanceBackend.run_instances

    def run_instances(self, *args: object, **kwargs: object):
        custom_id = extract(_find_tags(args, kwargs))
        if not custom_id:
            return original_run(self, *args, **kwargs)
        count = args[1] if len(args) > 1 else kwargs.get("count", 1)
        if int(count) != 1:
            _invalid(
                "ec2",
                custom_id,
                "RunInstances with _custom_id_ requires MinCount=MaxCount=1.",
            )
        _check("ec2", "instance", custom_id)
        if _instance_taken(self, custom_id):
            _invalid("ec2", custom_id, "That id is already in use.")
        return _with_random(
            instances,
            "random_instance_id",
            custom_id,
            lambda: original_run(self, *args, **kwargs),
        )

    instances.InstanceBackend.run_instances = run_instances


def _patch_elbv2() -> None:
    from moto.elbv2.models import ELBv2Backend
    from moto.moto_api._internal import mock_random

    original_hex = mock_random.get_random_hex

    def get_random_hex(length: int = 8) -> str:
        pending = getattr(_tls, "hex_id", None)
        if isinstance(pending, str):
            _tls.hex_id = None
            return pending
        return original_hex(length)

    mock_random.get_random_hex = get_random_hex

    def _wrap(method: str, kind: str, store_attr: str) -> None:
        original = getattr(ELBv2Backend, method)

        def wrapped(self, *args: object, **kwargs: object):
            custom_id = extract(_find_tags(args, kwargs))
            if not custom_id:
                return original(self, *args, **kwargs)
            _check("elbv2", kind, custom_id)
            if _arn_suffix_taken(getattr(self, store_attr, {}), custom_id):
                _invalid("elbv2", custom_id, "That ARN suffix is already in use.")
            _tls.hex_id = custom_id
            try:
                return original(self, *args, **kwargs)
            finally:
                _tls.hex_id = None

        setattr(ELBv2Backend, method, wrapped)

    _wrap("create_load_balancer", "lb-suffix", "load_balancers")
    _wrap("create_target_group", "tg-suffix", "target_groups")


def _patch_http_api() -> None:
    from moto.apigatewayv2.models import Api, ApiGatewayV2Backend
    from moto.utilities.utils import get_partition

    original_init = Api.__init__
    original_create = ApiGatewayV2Backend.create_api

    def create_api(self, *args: object, **kwargs: object):
        custom_id = extract(kwargs.get("tags"))
        if custom_id:
            _check("apigatewayv2", "http-api", custom_id)
            if custom_id in getattr(self, "apis", {}):
                _invalid("apigatewayv2", custom_id, "That id is already in use.")
        return original_create(self, *args, **kwargs)

    def api_init(self, *args: object, **kwargs: object) -> None:
        tags = kwargs.get("tags") if isinstance(kwargs.get("tags"), dict) else {}
        custom_id = extract(tags)
        original_init(self, *args, **kwargs)
        if not custom_id:
            return
        region = kwargs.get("region")
        if not isinstance(region, str):
            return
        old_arn = self.arn
        self.api_id = custom_id
        self.api_endpoint = f"https://{custom_id}.execute-api.{region}.amazonaws.com"
        self.arn = (
            f"arn:{get_partition(region)}:apigateway:{region}::/apis/{custom_id}"
        )
        tagger = getattr(self.backend, "tagger", None)
        stored = getattr(tagger, "tags", None)
        if isinstance(stored, dict) and old_arn in stored:
            stored[self.arn] = stored.pop(old_arn)

    ApiGatewayV2Backend.create_api = create_api
    Api.__init__ = api_init


def _patch_hosted_zone() -> None:
    import moto.route53.models as route53_models
    from moto.route53.responses import Route53

    original_zone_id = route53_models.create_route53_zone_id
    original_create = route53_models.Route53Backend.create_hosted_zone
    original_response = Route53.create_hosted_zone

    def create_route53_zone_id(*args: object, **kwargs: object) -> str:
        custom_id = getattr(_tls, "zone_id", None)
        if isinstance(custom_id, str):
            _tls.zone_id = None
            return custom_id
        return original_zone_id(*args, **kwargs)

    def create_hosted_zone(self, *args: object, **kwargs: object):
        custom_id = getattr(_tls, "zone_id", None)
        if isinstance(custom_id, str) and custom_id in getattr(self, "zones", {}):
            _tls.zone_id = None
            _invalid("route53", custom_id, "That hosted zone id is already in use.")
        return original_create(self, *args, **kwargs)

    def create_hosted_zone_response(self):
        custom_id = _hosted_zone_custom_id(self)
        if custom_id:
            _check("route53", "hosted-zone", custom_id)
            _tls.zone_id = custom_id
        try:
            return original_response(self)
        finally:
            _tls.zone_id = None

    route53_models.create_route53_zone_id = create_route53_zone_id
    route53_models.Route53Backend.create_hosted_zone = create_hosted_zone
    Route53.create_hosted_zone = create_hosted_zone_response


def _hosted_zone_custom_id(response: object) -> str | None:
    body = getattr(response, "body", None)
    if not body:
        return None
    try:
        import xmltodict

        parsed = xmltodict.parse(body)
    except Exception:
        LOG.debug("hosted zone body parse failed", exc_info=True)
        return None
    zone = parsed.get("CreateHostedZoneRequest")
    if not isinstance(zone, dict):
        return None
    custom_id = extract(zone.get("Tags"))
    if custom_id:
        return custom_id
    caller = zone.get("CallerReference")
    if isinstance(caller, str) and caller.startswith(ZONE_CALLER_PREFIX):
        return caller[len(ZONE_CALLER_PREFIX) :]
    return None


def _patch_ecs() -> None:
    from moto.ecs.models import Cluster

    original_init = Cluster.__init__

    def cluster_init(
        self,
        cluster_name: str,
        account_id: str,
        region_name: str,
        cluster_settings: object = None,
        configuration: object = None,
        capacity_providers: object = None,
        default_capacity_provider_strategy: object = None,
        tags: object = None,
        service_connect_defaults: object = None,
    ) -> None:
        original_init(
            self,
            cluster_name,
            account_id,
            region_name,
            cluster_settings,
            configuration,
            capacity_providers,
            default_capacity_provider_strategy,
            tags,
            service_connect_defaults,
        )
        custom_id = extract(tags)
        if not custom_id:
            return
        match = _ECS_ARN.fullmatch(custom_id)
        if match is None or match.group(1) != cluster_name:
            _invalid(
                "ecs",
                custom_id,
                "Expected arn:<partition>:ecs:<region>:<account>:cluster/"
                + cluster_name,
            )
        self.arn = custom_id

    Cluster.__init__ = cluster_init


def _apply() -> None:
    _patch_ec2()
    _patch_elbv2()
    _patch_http_api()
    _patch_hosted_zone()
    _patch_ecs()
    LOG.info("awsbox custom resource ids applied")
    print("awsbox custom resource ids applied", flush=True)


_apply()
