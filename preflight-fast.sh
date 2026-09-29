#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
fail=0
warn=0
pass() { printf '[PASS] %s\n' "$*"; }
miss() { printf '[MISS] %s\n' "$*"; fail=1; }
info() { printf '[INFO] %s\n' "$*"; }

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  info "host=${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" == ubuntu ]]; then pass "Ubuntu host"; else info "scratch host is not Ubuntu; target workflow is Ubuntu 24.04"; fi
fi

if DISPLAY=:88 XAUTHORITY="$ROOT/run/x11/Xauthority" timeout 3 xdpyinfo >/dev/null 2>&1; then
  pass "authenticated X11 :88"
else
  miss "authenticated X11 :88"
fi
if ss -ltn 2>/dev/null | grep -q ':6088'; then
  miss "X11 TCP must remain closed"
else
  pass "X11 TCP closed"
fi

if [[ -x "$ROOT/runtime/qemu-wine32-bin/wine" && -x "$ROOT/runtime/qemu-i386-static" ]]; then
  pass "validated qemu32 client lane present"
elif [[ -x "$ROOT/runtime/wine-11.18-staging-amd64-wow64/bin/wine" ]]; then
  info "wow64 fallback present; qemu32 validated lane is not restored yet"
else
  miss "Wine client runtime"
fi

if [[ -f "$ROOT/client/ChromieCraft_3.3.5a/Wow.exe" ]]; then
  pass "ChromieCraft client present"
else
  miss "ChromieCraft client build 12340 warm layer"
fi

if [[ -x "$ROOT/native/trinitycore-mysql-server-patch/bin/worldserver" || -x "$ROOT/runtime/trinitycore/install/bin/worldserver" ]]; then
  pass "TrinityCore worldserver runtime present"
else
  miss "pinned TrinityCore runtime f5f9bac"
fi

DATA_A="$ROOT/native/recovery-bundle/data"
DATA_B="$ROOT/state/game-data"
if [[ -f "$DATA_A/.extraction-complete" || -f "$DATA_B/.extraction-complete" ]]; then
  pass "DBC/maps/vmaps/mmaps warm data marker present"
else
  miss "DBC/maps/vmaps/mmaps warm data layer"
fi

if [[ -f "$ROOT/state/db/auth.sql.zst" && -f "$ROOT/state/db/characters.sql.zst" && -f "$ROOT/state/db/world.sql.zst" ]]; then
  pass "logical database recovery snapshot present"
else
  miss "logical database recovery snapshot"
fi

if [[ "$fail" -eq 0 ]]; then
  echo 'fast_recall=ready'
  exit 0
fi
echo 'fast_recall=missing_warm_layers'
exit 2
