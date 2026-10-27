#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/security/acm-smoke.sh" "$@"
