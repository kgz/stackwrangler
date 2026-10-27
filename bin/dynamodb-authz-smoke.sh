#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/data/dynamodb-authz-smoke.sh" "$@"
