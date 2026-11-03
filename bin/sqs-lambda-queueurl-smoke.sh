#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/lambda/sqs-lambda-queueurl-smoke.sh" "$@"
