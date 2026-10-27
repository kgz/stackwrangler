#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/messaging/sns-sqs-fanout-smoke.sh" "$@"
