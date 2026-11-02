#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/messaging/sns-filter-policy-limits-smoke.sh" "$@"
