#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPLAY_NUM="${WOW_DISPLAY_NUM:-88}"
SCREEN="${WOW_SCREEN:-2560x1440x24}"
AUTH_DIR="${WOW_XAUTH_DIR:-$ROOT/run/x11}"
AUTH_FILE="$AUTH_DIR/Xauthority"
PID_FILE="$AUTH_DIR/Xvfb.pid"
LOG_FILE="$ROOT/logs/xvfb-${DISPLAY_NUM}.log"
mkdir -p "$AUTH_DIR" "$ROOT/logs"
chmod 700 "$AUTH_DIR"

alive() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
authorized() { [[ -s "$AUTH_FILE" ]] && DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$AUTH_FILE" timeout 4 xdpyinfo >/dev/null 2>&1; }

# Never rewrite a live display's authority file. Reuse it if it still authenticates.
if alive && authorized; then
  echo "display=ready endpoint=:$DISPLAY_NUM auth=$AUTH_FILE"
  exit 0
fi

# If the PID we recorded is dead, remove only our stale PID file. Never delete X sockets/locks here.
if [[ -f "$PID_FILE" ]] && ! alive; then
  rm -f "$PID_FILE"
fi

# Refuse to take over another display. This keeps canonical :88 owner-gated.
if [[ -S "/tmp/.X11-unix/X$DISPLAY_NUM" ]] || [[ -e "/tmp/.X${DISPLAY_NUM}-lock" ]]; then
  echo "Refusing to replace an existing display :$DISPLAY_NUM; authority did not validate." >&2
  exit 3
fi

# Create fresh private client/server authority only when starting a new display.
umask 077
: > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"
cookie="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
printf 'add :%s MIT-MAGIC-COOKIE-1 %s\n' "$DISPLAY_NUM" "$cookie" | xauth -f "$AUTH_FILE" source - >/dev/null
unset cookie

nohup Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp -auth "$AUTH_FILE" >"$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
for _ in $(seq 1 40); do
  if authorized; then
    DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$AUTH_FILE" nohup openbox >>"$ROOT/logs/openbox-${DISPLAY_NUM}.log" 2>&1 &
    echo "display=started endpoint=:$DISPLAY_NUM auth=$AUTH_FILE"
    exit 0
  fi
  sleep 0.1
done

echo "Xvfb :$DISPLAY_NUM failed authorization probe" >&2
exit 4
