#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/apigw/apigw-smoke.sh" "$@"
