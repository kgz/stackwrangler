#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/iac/serverless-v4-smoke.sh" "$@"
