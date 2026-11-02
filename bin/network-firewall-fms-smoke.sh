#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/networking/network-firewall-fms-smoke.sh" "$@"
