#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/messaging/sfn-authz-smoke.sh" "$@"
