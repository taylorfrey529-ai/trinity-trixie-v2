#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "workspace=$ROOT"
[[ -x "$ROOT/runtime/wine-11.18-staging-amd64-wow64/bin/wine" ]] && echo wine=ready || echo wine=missing
[[ -f "$ROOT/client/ChromieCraft_3.3.5a/Wow.exe" ]] && echo client=ready || echo client=missing
DISPLAY=:88 XAUTHORITY="$ROOT/run/x11/Xauthority" timeout 3 xdpyinfo >/dev/null 2>&1 && echo display=ready || echo display=missing
"$ROOT/server.sh" status 2>/dev/null || echo server=not-ready
