#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/messaging/sns-authz-smoke.sh" "$@"
