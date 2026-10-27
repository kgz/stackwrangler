#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/data/rds-authz-smoke.sh" "$@"
