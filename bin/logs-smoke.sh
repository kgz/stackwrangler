#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/logs/logs-smoke.sh" "$@"
