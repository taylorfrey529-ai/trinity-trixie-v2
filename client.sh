#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CLIENT_ROOT="${WOW_CLIENT_ROOT:-$ROOT/client/ChromieCraft_3.3.5a}"
MODE="${WOW_WINE_MODE:-qemu32}"

if [[ "$MODE" == "qemu32" ]]; then
  WINE_ROOT="${WINE_ROOT:-$ROOT/runtime/wine-11.18-staging-x86-qemu}"
  WINE="${WINE:-$ROOT/runtime/qemu-wine32-bin/wine}"
  WINESERVER="${WINESERVER:-$ROOT/runtime/qemu-wine32-bin/wineserver}"
  WINEPREFIX="${WINEPREFIX:-$ROOT/runtime/wine-prefix-wow335-qemu32}"
  WINE32_ROOTFS="${WINE32_ROOTFS:-$ROOT/runtime/wine32-qemu-rootfs}"
  QEMU_I386="${QEMU_I386:-$ROOT/runtime/qemu-i386-static}"
  export WINEARCH=win32
  export WINELOADER="$WINE_ROOT/lib/wine/i386-unix/wine"
  export WINESERVER
  unset WINELOADERNOEXEC || true
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml,winegstreamer=}"
  export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
  if [[ -d "$WINE32_ROOTFS/usr/lib/i386-linux-gnu/dri" ]]; then
    export LIBGL_DRIVERS_PATH="$WINE32_ROOTFS/usr/lib/i386-linux-gnu/dri${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"
  fi
else
  WINE_ROOT="${WINE_ROOT:-$ROOT/runtime/wine-11.18-staging-amd64-wow64}"
  WINE="${WINE:-$WINE_ROOT/bin/wine}"
  WINESERVER="${WINESERVER:-$WINE_ROOT/bin/wineserver}"
  WINEPREFIX="${WINEPREFIX:-$ROOT/runtime/wine-prefix}"
  export WINEARCH="${WINEARCH:-wow64}"
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml,winegstreamer=}"
fi
export WINEPREFIX

WINE_SERVER_LOG="$ROOT/native/client-wineserver.log"

start_wineserver() {
  mkdir -p "$ROOT/native"
  "$WINESERVER" -p0 >>"$WINE_SERVER_LOG" 2>&1 || true
  sleep 0.5
}

stop_wineserver() {
  "$WINESERVER" -k >/dev/null 2>&1 || true
}

display_reachable() {
  [[ -n "${DISPLAY:-}" ]] || return 1
  if command -v xdpyinfo >/dev/null 2>&1; then
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
    return $?
  fi
  if [[ "$DISPLAY" =~ ^:([0-9]+)(\.[0-9]+)?$ ]]; then
    [[ -S "/tmp/.X11-unix/X${BASH_REMATCH[1]}" ]]
    return $?
  fi
  return 1
}

find_locale_dir() {
  local d
  for d in enUS enGB deDE esES esMX frFR ruRU koKR zhCN zhTW; do
    if [[ -d "$CLIENT_ROOT/Data/$d" ]]; then
      printf '%s\n' "$CLIENT_ROOT/Data/$d"
      return 0
    fi
  done
  return 1
}

client_preflight() {
  local failed=0 locale=""
  [[ -x "$WINE" ]] || { echo "Missing Wine launcher: $WINE" >&2; failed=1; }
  [[ -x "$WINESERVER" ]] || { echo "Missing wineserver launcher: $WINESERVER" >&2; failed=1; }
  [[ -f "$CLIENT_ROOT/Wow.exe" ]] || { echo "Missing client executable: $CLIENT_ROOT/Wow.exe" >&2; failed=1; }
  if [[ "$MODE" == "qemu32" ]]; then
    [[ -x "$QEMU_I386" ]] || { echo "Missing qemu-i386: $QEMU_I386" >&2; failed=1; }
    [[ -x "$WINE_ROOT/lib/wine/i386-unix/wine-preloader" ]] || { echo "Missing Wine i386 preloader." >&2; failed=1; }
    [[ -x "$WINE_ROOT/lib/wine/i386-unix/wine.qemu-real" ]] || { echo "Missing preserved Wine i386 loader." >&2; failed=1; }
    [[ -e "$WINE32_ROOTFS/lib/ld-linux.so.2" ]] || { echo "Missing i386 runtime rootfs loader." >&2; failed=1; }
    [[ -f "$WINE32_ROOTFS/usr/lib/i386-linux-gnu/libEGL_mesa.so.0" ]] || { echo "Missing i386 Mesa EGL vendor library." >&2; failed=1; }
    [[ -f "$WINE32_ROOTFS/usr/share/glvnd/egl_vendor.d/50_mesa.json" ]] || { echo "Missing Mesa EGL vendor metadata." >&2; failed=1; }
    grep -q -- "-R '0x100000000'" "$WINE_ROOT/lib/wine/i386-unix/wine" || { echo "Wine qemu wrapper is missing the 4 GiB guest VA reservation." >&2; failed=1; }
    grep -q -- "-R '0x100000000'" "$WINESERVER" || { echo "wineserver qemu wrapper is missing the 4 GiB guest VA reservation." >&2; failed=1; }
  fi
  if locale="$(find_locale_dir 2>/dev/null)"; then
    echo "Locale directory: $locale"
  else
    echo "No supported client locale directory found under $CLIENT_ROOT/Data" >&2
    failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then return 2; fi
  echo "Wine mode: $MODE"
  echo "Wine: $($WINE --version 2>/dev/null || true)"
  echo "Client: $CLIENT_ROOT/Wow.exe"
  echo "WINEPREFIX: $WINEPREFIX"
  if display_reachable; then
    echo "DISPLAY: $DISPLAY (reachable)"
  elif [[ -n "${DISPLAY:-}" ]]; then
    echo "DISPLAY: $DISPLAY (set but unreachable; GUI launch is unavailable)"
  else
    echo "DISPLAY is not set; GUI launch is unavailable in this shell."
  fi
}

configure_realmlist() {
  local locale realmlist backup
  locale="$(find_locale_dir)" || { echo "Client locale directory not found." >&2; return 2; }
  realmlist="$locale/realmlist.wtf"
  if [[ -f "$realmlist" ]] && ! grep -qx 'set realmlist 127.0.0.1' "$realmlist"; then
    backup="$realmlist.before-local.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$realmlist" "$backup"
    echo "Backup: $backup"
  fi
  printf '%s\n' 'set realmlist 127.0.0.1' > "$realmlist"
  echo "Configured: $realmlist"
  cat "$realmlist"
}

init_prefix() {
  mkdir -p "$WINEPREFIX"
  start_wineserver
  if [[ -f "$WINEPREFIX/system.reg" ]]; then
    echo "Wine prefix already initialized: $WINEPREFIX"
    return 0
  fi
  echo "Initializing Wine prefix: $WINEPREFIX"
  WINEDEBUG=-all "$WINE" wineboot.exe -u
  [[ -f "$WINEPREFIX/system.reg" ]] || { echo "Wine prefix initialization did not complete." >&2; return 1; }
}

wine_runtime_check() {
  start_wineserver
  local out rc=0
  out="$(WINEDEBUG=-all "$WINE" cmd.exe /c echo WOW_WINE_OK 2>&1)" || rc=$?
  stop_wineserver
  [[ "$rc" -eq 0 && "$out" == *WOW_WINE_OK* ]] || { printf '%s\n' "$out" >&2; return 1; }
  echo "Wine 32-bit process bootstrap: OK"
}

server_ports() {
  local p
  for p in 3724 8085; do
    if ss -ltn 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${p}[[:space:]]"; then
      echo "127.0.0.1:$p ready"
    else
      echo "127.0.0.1:$p not listening"
    fi
  done
}

launch_client() {
  client_preflight
  configure_realmlist
  init_prefix
  server_ports
  if ! display_reachable; then
    if [[ -n "${DISPLAY:-}" ]]; then
      echo "Cannot launch Wow.exe: DISPLAY=$DISPLAY is not reachable." >&2
    else
      echo "Cannot launch Wow.exe: DISPLAY is not set." >&2
    fi
    return 3
  fi
  local win_client
  win_client="${CLIENT_ROOT//\//\\}"
  export WINEDEBUG="${WINEDEBUG:--all}"
  start_wineserver
  if [[ $# -eq 0 ]]; then
    set -- -opengl
  fi
  exec "$WINE" "Z:${win_client}\\Wow.exe" "$@"
}

case "${1:-help}" in
  preflight|check) client_preflight ;;
  configure|realm-local) configure_realmlist ;;
  init-wine) init_prefix ;;
  wine-check) wine_runtime_check ;;
  server-ports) server_ports ;;
  launch) shift; launch_client "$@" ;;
  stop-wine) stop_wineserver ;;
  help|*)
    cat <<TXT
Usage: ./client.sh <command>

  preflight/check   verify the WoW client and selected Wine runtime
  configure         set Data/<locale>/realmlist.wtf to 127.0.0.1
  init-wine         initialize the isolated Wine prefix
  wine-check        execute a 32-bit Windows command through the runtime
  server-ports      show local auth/world listener readiness
  launch            configure, initialize, and launch Wow.exe (defaults to -opengl)
  stop-wine         stop processes in this Wine prefix

Client root: $CLIENT_ROOT
Wine mode:   $MODE
Wine root:   $WINE_ROOT
Wine prefix: $WINEPREFIX
TXT
    ;;
esac
