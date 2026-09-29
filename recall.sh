#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export WOW_WINE_MODE="${WOW_WINE_MODE:-wow64}"
export WINE_ROOT="${WINE_ROOT:-$ROOT/runtime/wine-11.18-staging-amd64-wow64}"
export WOW_CLIENT_ROOT="${WOW_CLIENT_ROOT:-$ROOT/client/ChromieCraft_3.3.5a}"
export DISPLAY="${DISPLAY:-:88}"
export XAUTHORITY="${XAUTHORITY:-$ROOT/run/x11/Xauthority}"

"$ROOT/scripts/prepare-runtime.sh"
"$ROOT/scripts/ensure-display.sh"

server_ready=0
if "$ROOT/server.sh" preflight >/tmp/wow-server-preflight.log 2>&1; then
  server_ready=1
  "$ROOT/server.sh" start
else
  echo "server=not-ready"
  sed -n '1,120p' /tmp/wow-server-preflight.log >&2
fi

client_ready=0
if "$ROOT/scripts/ensure-client.sh"; then client_ready=1; else true; fi

if [[ "$server_ready" -eq 1 ]]; then "$ROOT/server.sh" status; fi
if [[ "$client_ready" -eq 1 ]]; then
  "$ROOT/client.sh" configure || true
  "$ROOT/client.sh" preflight
  if [[ "${WOW_NO_LAUNCH:-0}" != "1" ]]; then "$ROOT/client.sh" launch; fi
fi

if [[ "$server_ready" -eq 1 && "$client_ready" -eq 1 ]]; then
  echo "recall=ready"
else
  echo "recall=partial server_ready=$server_ready client_ready=$client_ready"
  exit 2
fi
