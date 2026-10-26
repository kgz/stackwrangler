"""Shared helpers for SQS / Lambda ESM start.d patches (#266, #363).

Mounted at ``/opt/awsbox/esm/awsbox_esm_common.py``. Start scripts add that
directory to ``sys.path`` and ``import awsbox_esm_common``.
"""

from __future__ import annotations


def request_get(request, key: str):
    if request is None:
        return None
    if isinstance(request, dict):
        return request.get(key)
    getter = getattr(request, "get", None)
    if callable(getter):
        return getter(key)
    return getattr(request, key, None)


def get_function_version(function_ref: str, account_id: str, region: str):
    """Resolve a CreateEventSourceMapping FunctionName/Arn to a version config holder.

    Returns None when the function is missing. Raises on store/locator errors.
    """
    from localemu.services.lambda_ import api_utils
    from localemu.services.lambda_.api_utils import function_locators_from_arn
    from localemu.services.lambda_.invocation.models import lambda_stores
    from localemu.services.lambda_.provider_utils import get_function_version_from_arn

    function_name, qualifier, account, fn_region = function_locators_from_arn(function_ref)
    account = account or account_id
    fn_region = fn_region or region
    state = lambda_stores[account][fn_region]
    fn = state.functions.get(function_name)
    if not fn:
        return None
    if qualifier:
        fn_arn = api_utils.qualified_lambda_arn(function_name, qualifier, account, fn_region)
    else:
        fn_arn = api_utils.unqualified_lambda_arn(function_name, account, fn_region)
    return get_function_version_from_arn(fn_arn)
