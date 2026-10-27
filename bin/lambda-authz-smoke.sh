#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/lambda/lambda-authz-smoke.sh" "$@"
