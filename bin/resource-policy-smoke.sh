#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/security/resource-policy-smoke.sh" "$@"
