#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/lambda/sqs-lambda-dlq-smoke.sh" "$@"
