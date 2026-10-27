#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/security/multi-account-smoke.sh" "$@"
