#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/networking/vpce-private-dns-smoke.sh" "$@"
