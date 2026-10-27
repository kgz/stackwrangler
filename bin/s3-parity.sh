#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/s3/s3-parity.sh" "$@"
