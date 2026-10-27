#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/data/dynamodb-depth-smoke.sh" "$@"
