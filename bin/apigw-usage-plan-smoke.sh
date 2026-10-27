#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/apigw/apigw-usage-plan-smoke.sh" "$@"
