#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/transfer/transfer-sftp-port-smoke.sh" "$@"
