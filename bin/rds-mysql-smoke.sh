#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/data/rds-mysql-smoke.sh" "$@"
