#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/lambda/sqs-lambda-esm-enable-smoke.sh" "$@"
