#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SERVER="$ROOT/native/recovery-bundle"
INSTALL="$SERVER/install"
SERVER_PATCH="${TC_SERVER_PATCH:-$ROOT/native/trinitycore-mysql-server-patch}"
SERVER_BIN="$SERVER_PATCH/bin"
SERVER_PATCH_LIB="$SERVER_PATCH/lib"
CONF="$ROOT/config/trinity"
RUN="$SERVER/run"
LOGS="$SERVER/logs"
DATA="$SERVER/data"
ENV_FILE="$ROOT/.env"
MYSQL="$ROOT/mysql.sh"
LIBS="$SERVER_PATCH_LIB:$INSTALL/lib"

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; return 2; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

pid_alive() { [[ "${1:-}" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
pid_file() { echo "$RUN/$1.pid"; }
get_pid() { local f; f="$(pid_file "$1")"; [[ -f "$f" ]] && cat "$f" 2>/dev/null || true; }
port_ready() { ss -ltn 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${1}[[:space:]]"; }
port_owned_by() {
  local port="$1" pid="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ss -ltnp 2>/dev/null | grep -E "127\.0\.0\.1:${port}[[:space:]]" | grep -q "pid=${pid},"
}

require_install() {
  [[ -x "$SERVER_BIN/worldserver" && -x "$SERVER_BIN/authserver" ]] || {
    echo "TrinityCore MySQL-linked server overlay is not installed yet: $SERVER_PATCH" >&2; return 2; }
  [[ -f "$CONF/worldserver.conf" && -f "$CONF/authserver.conf" ]] || {
    echo "TrinityCore is not configured; run ./scripts/configure-trinity.sh" >&2; return 2; }
}

start_service() {
  local svc="$1" bin="$2" cfg="$3" port="$4" pid fifo
  mkdir -p "$RUN" "$LOGS"
  pid="$(get_pid "$svc")"
  if port_ready "$port"; then
    if pid_alive "$pid" && port_owned_by "$port" "$pid"; then
      echo "$svc already ready (pid=$pid)."
      return 0
    fi
    echo "$svc port 127.0.0.1:$port is already owned by an unmanaged/different process." >&2
    return 4
  fi
  if pid_alive "$pid"; then
    echo "$svc tracked pid $pid is alive but not listening on 127.0.0.1:$port." >&2
    return 4
  fi
  rm -f "$(pid_file "$svc")"
  if [[ "$svc" == worldserver ]]; then
    fifo="$RUN/worldserver.console"
    [[ -p "$fifo" ]] || { rm -f "$fifo"; mkfifo -m 600 "$fifo"; }
    setsid bash -c 'exec 3<>"$1"; cd "$2"; export LD_LIBRARY_PATH="$3"; exec "$4" -c "$5" <&3 >>"$6" 2>&1' \
      _ "$fifo" "$SERVER" "$LIBS" "$bin" "$cfg" "$LOGS/worldserver-console.log" >/dev/null 2>&1 &
  else
    setsid bash -c 'cd "$1"; export LD_LIBRARY_PATH="$2"; exec "$3" -c "$4" >>"$5" 2>&1' \
      _ "$SERVER" "$LIBS" "$bin" "$cfg" "$LOGS/authserver-console.log" >/dev/null 2>&1 &
  fi
  echo $! > "$(pid_file "$svc")"
  pid=$!
  for _ in $(seq 1 1200); do
    if port_ready "$port"; then
      if port_owned_by "$port" "$pid"; then
        echo "$svc ready (pid=$pid, 127.0.0.1:$port)."
        return 0
      fi
      echo "$svc detected a listener on 127.0.0.1:$port owned by a different process." >&2
      kill -INT "$pid" 2>/dev/null || true
      return 4
    fi
    if ! pid_alive "$pid"; then
      echo "$svc exited before opening port $port." >&2
      tail -120 "$LOGS/${svc}-console.log" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "$svc did not open port $port within 10 minutes." >&2
  tail -120 "$LOGS/${svc}-console.log" >&2 || true
  return 1
}

stop_service() {
  local svc="$1" pid
  pid="$(get_pid "$svc")"
  if ! pid_alive "$pid"; then rm -f "$(pid_file "$svc")"; echo "$svc already stopped."; return 0; fi
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    pid_alive "$pid" || { rm -f "$(pid_file "$svc")"; echo "$svc stopped."; return 0; }
    sleep 0.25
  done
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    pid_alive "$pid" || { rm -f "$(pid_file "$svc")"; echo "$svc stopped."; return 0; }
    sleep 0.25
  done
  echo "$svc did not stop cleanly (pid=$pid)." >&2
  return 1
}

preflight() {
  local fail=0
  "$MYSQL" status || fail=1
  if ! require_install; then fail=1; fi
  if [[ -d "$SERVER" ]]; then
    local b d
    for b in authserver worldserver; do
      [[ -x "$SERVER_BIN/$b" ]] || { echo "missing_server_binary=$b"; fail=1; }
    done
    if [[ -x "$SERVER_BIN/worldserver" ]]; then
      linkage="$(LD_LIBRARY_PATH="$LIBS" ldd "$SERVER_BIN/worldserver" 2>&1 || true)"
      [[ "$linkage" == *libmysqlclient* ]] || { echo "server_mysql_abi=missing_libmysqlclient"; fail=1; }
      [[ "$linkage" != *libmariadb* ]] || { echo "server_mysql_abi=unexpected_libmariadb"; fail=1; }
      [[ "$linkage" != *'not found'* ]] || { echo "server_linkage=unresolved_dependency"; fail=1; }
    fi
    for b in mapextractor vmap4extractor vmap4assembler mmaps_generator; do
      [[ -x "$INSTALL/bin/$b" ]] || { echo "missing_tool_binary=$b"; fail=1; }
    done
    for d in dbc maps vmaps mmaps; do
      [[ -d "$DATA/$d" ]] || { echo "missing_data=$d"; fail=1; }
    done
    [[ -f "$DATA/.extraction-complete" ]] || { echo "missing_data_marker=.extraction-complete"; fail=1; }
  fi
  [[ "$fail" -eq 0 ]] && echo 'preflight=pass' || { echo 'preflight=incomplete'; return 2; }
}

bootstrap_db() {
  require_install
  load_env
  "$MYSQL" start
  local count
  count="$($MYSQL query "$TC_AUTH_DB" "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='$TC_AUTH_DB'" | tail -1 | cut -f1)"
  if [[ "$count" == 0 ]]; then "$MYSQL" import "$TC_AUTH_DB" "$SERVER/source/sql/base/auth_database.sql"; else echo "auth already populated ($count tables)."; fi
  count="$($MYSQL query "$TC_CHAR_DB" "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='$TC_CHAR_DB'" | tail -1 | cut -f1)"
  if [[ "$count" == 0 ]]; then "$MYSQL" import "$TC_CHAR_DB" "$SERVER/source/sql/base/characters_database.sql"; else echo "characters already populated ($count tables)."; fi
  count="$($MYSQL query "$TC_WORLD_DB" "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='$TC_WORLD_DB'" | tail -1 | cut -f1)"
  if [[ "$count" == 0 ]]; then
    mapfile -t tdbs < <(find "$SERVER/tdb" -maxdepth 1 -type f -name 'TDB_full_world_335*.sql' -print | sort)
    [[ ${#tdbs[@]} -eq 1 ]] || { echo "Expected one TDB SQL file." >&2; return 3; }
    "$MYSQL" import "$TC_WORLD_DB" "${tdbs[0]}"
  else echo "world already populated ($count tables)."; fi
  realm_local
}

realm_show() {
  load_env
  "$MYSQL" query "$TC_AUTH_DB" 'SELECT id,name,address,localAddress,localSubnetMask,port,gamebuild FROM realmlist ORDER BY id'
}
realm_local() {
  load_env
  "$MYSQL" query "$TC_AUTH_DB" "UPDATE realmlist SET name='Cubase AI Local Trinity',address='127.0.0.1',localAddress='127.0.0.1',localSubnetMask='255.255.255.0',port=8085,gamebuild=12340 WHERE id=1" >/dev/null
  realm_show
}

status_all() {
  local svc port pid state
  printf '%-12s %-9s %-8s %s\n' SERVICE PID PORT STATE
  if "$MYSQL" status >/dev/null 2>&1; then printf '%-12s %-9s %-8s %s\n' mysql "$(cat "$ROOT/native/mysql-run/mysqld.pid" 2>/dev/null || echo -)" 3306 ready; else printf '%-12s %-9s %-8s %s\n' mysql - 3306 stopped; fi
  for row in 'authserver 3724' 'worldserver 8085'; do
    set -- $row; svc="$1"; port="$2"; pid="$(get_pid "$svc")"; state=stopped
    if pid_alive "$pid"; then
      if port_owned_by "$port" "$pid"; then state=ready
      elif port_ready "$port"; then state=conflict
      else state=starting
      fi
    else
      if port_ready "$port"; then state=unmanaged; else state=stopped; fi
      pid=-
    fi
    printf '%-12s %-9s %-8s %s\n' "$svc" "$pid" "$port" "$state"
  done
}

send_command() {
  local fifo="$RUN/worldserver.console"
  [[ -p "$fifo" ]] || { echo "World console is unavailable." >&2; return 2; }
  [[ $# -gt 0 ]] || { echo "Usage: ./server.sh command 'server command'" >&2; return 2; }
  printf '%s\n' "$*" > "$fifo"
}

backup_db() {
  mkdir -p "$ROOT/backups"
  local stamp file mysql_was=0 auth_was=0 world_was=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; file="$ROOT/backups/mysql-data-$stamp.tar.gz"
  "$MYSQL" status >/dev/null 2>&1 && mysql_was=1 || true
  pid_alive "$(get_pid authserver)" && auth_was=1 || true
  pid_alive "$(get_pid worldserver)" && world_was=1 || true
  [[ "$auth_was" -eq 1 ]] && stop_service authserver || true
  [[ "$world_was" -eq 1 ]] && stop_service worldserver || true
  [[ "$mysql_was" -eq 1 ]] && "$MYSQL" stop || true
  tar -C "$ROOT/native" -czf "$file" mysql-data
  chmod 600 "$file"
  [[ "$mysql_was" -eq 1 ]] && "$MYSQL" start || true
  if [[ "$world_was" -eq 1 ]]; then start_service worldserver "$SERVER_BIN/worldserver" "$CONF/worldserver.conf" 8085; fi
  if [[ "$auth_was" -eq 1 ]]; then start_service authserver "$SERVER_BIN/authserver" "$CONF/authserver.conf" 3724; fi
  echo "Backup written: $file"
}

case "${1:-help}" in
  configure) "$ROOT/scripts/configure-trinity.sh" ;;
  db-bootstrap) bootstrap_db ;;
  data-finalize) "$ROOT/scripts/finalize-mmaps.sh" ;;
  preflight|check) preflight ;;
  start)
    require_install; "$MYSQL" start
    preflight
    start_service worldserver "$SERVER_BIN/worldserver" "$CONF/worldserver.conf" 8085
    start_service authserver "$SERVER_BIN/authserver" "$CONF/authserver.conf" 3724
    ;;
  stop) stop_service authserver || true; stop_service worldserver || true; "$MYSQL" stop ;;
  restart) "$0" stop; "$0" start ;;
  status) status_all ;;
  logs) tail -F -n 200 "$LOGS/${2:-worldserver}-console.log" ;;
  command) shift; send_command "$@" ;;
  realm-show) realm_show ;;
  realm-local) realm_local ;;
  backup) backup_db ;;
  help|*)
    cat <<'TXT'
Usage: ./server.sh <command>

  configure       generate loopback-only TrinityCore configs
  db-bootstrap    import auth/characters/TDB world bases if each DB is empty
  data-finalize   validate completed mmaps output and write the extraction marker
  preflight/check verify MySQL, binaries, configs, and extracted game data
  start           start MySQL, worldserver, then authserver
  stop            stop authserver, worldserver, and MySQL
  restart         restart all services
  status          show PID/port/readiness
  logs [service]  follow server log (worldserver or authserver)
  command <text>  send one worldserver console command
  realm-show      display local realm record
  realm-local     force realm 1 to 127.0.0.1:8085 build 12340
  backup          cold-backup the MySQL datadir and restore prior running state
TXT
    ;;
esac
