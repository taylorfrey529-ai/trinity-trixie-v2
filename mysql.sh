#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT/.env"
CFG="$ROOT/config/mysql-local.cnf"
MYSQL_ROOT="$ROOT/runtime/mysql-8.4.11/usr"
MYSQLD="$MYSQL_ROOT/sbin/mysqld"
SQLCTL="$ROOT/runtime/bin/mysqlctl"
LIBAIO="$ROOT/runtime/libaio-0.3.113/lib"
LIBS="$LIBAIO:$MYSQL_ROOT/lib/x86_64-linux-gnu"
RUN="$ROOT/native/mysql-run"
SOCK="$RUN/mysql.sock"
PIDFILE="$RUN/mysqld.pid"
LOG="$RUN/mysqld.log"

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; return 2; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

pid_alive() {
  [[ -f "$PIDFILE" ]] || return 1
  local p
  p="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null
}

app_ping() {
  load_env
  MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER="$TC_DB_USER" MYSQL_PASSWORD="$TC_DB_PASSWORD" \
    "$SQLCTL" ping
}

start_db() {
  load_env
  if pid_alive; then
    echo "MySQL already running: pid=$(cat "$PIDFILE")"
    app_ping
    return 0
  fi
  mkdir -p "$RUN" "$ROOT/native/mysql-files"
  rm -f "$SOCK" "$PIDFILE"
  setsid env LD_LIBRARY_PATH="$LIBS" "$MYSQLD" --defaults-file="$CFG" --user=root \
    >/dev/null 2>&1 < /dev/null &
  local launcher=$!
  for _ in $(seq 1 60); do
    if [[ -S "$SOCK" ]] && pid_alive; then
      if app_ping >/dev/null 2>&1; then
        echo "MySQL ready: pid=$(cat "$PIDFILE") 127.0.0.1:3306"
        return 0
      fi
    fi
    if ! kill -0 "$launcher" 2>/dev/null && ! pid_alive; then
      echo "MySQL exited during startup." >&2
      tail -80 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "MySQL did not become ready." >&2
  tail -80 "$LOG" >&2 || true
  return 1
}

stop_db() {
  if ! pid_alive; then
    echo "MySQL is not running."
    rm -f "$PIDFILE" "$SOCK"
    return 0
  fi
  local p
  p="$(cat "$PIDFILE")"
  kill -TERM "$p"
  for _ in $(seq 1 60); do
    kill -0 "$p" 2>/dev/null || { rm -f "$PIDFILE" "$SOCK"; echo "MySQL stopped."; return 0; }
    sleep 1
  done
  echo "MySQL did not stop within 60 seconds (pid=$p)." >&2
  return 1
}

status_db() {
  if pid_alive; then
    echo "pid=$(cat "$PIDFILE") status=running"
    if ss -ltn 2>/dev/null | grep -qE '127\.0\.0\.1:3306[[:space:]]'; then
      echo "listener=127.0.0.1:3306"
    else
      echo "listener=missing"
    fi
    app_ping
  else
    echo "status=stopped"
    return 1
  fi
}

check_db() {
  load_env
  app_ping
  local db
  for db in "$TC_AUTH_DB" "$TC_CHAR_DB" "$TC_WORLD_DB"; do
    echo "database=$db"
    MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER="$TC_DB_USER" MYSQL_PASSWORD="$TC_DB_PASSWORD" \
      "$SQLCTL" query "$db" 'SELECT DATABASE() AS db, CURRENT_USER() AS account, @@version AS version'
  done
}

query_db() {
  load_env
  local db="$1"; shift
  MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER="$TC_DB_USER" MYSQL_PASSWORD="$TC_DB_PASSWORD" \
    "$SQLCTL" query "$db" "$@"
}

import_db() {
  load_env
  local db="$1" file="$2"
  [[ -f "$file" ]] || { echo "SQL file not found: $file" >&2; return 2; }
  MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER="$TC_DB_USER" MYSQL_PASSWORD="$TC_DB_PASSWORD" \
    "$SQLCTL" file "$db" "$file"
}

case "${1:-help}" in
  start) start_db ;;
  stop) stop_db ;;
  restart) stop_db; start_db ;;
  status) status_db ;;
  check) check_db ;;
  query)
    [[ $# -ge 3 ]] || { echo "Usage: $0 query DATABASE SQL" >&2; exit 2; }
    db="$2"; shift 2; query_db "$db" "$@"
    ;;
  import)
    [[ $# -eq 3 ]] || { echo "Usage: $0 import DATABASE FILE.sql" >&2; exit 2; }
    import_db "$2" "$3"
    ;;
  help|*)
    cat <<TXT
Usage: ./mysql.sh <command>

  start                start loopback-only MySQL 8.4.11
  stop                 cleanly stop the local MySQL process
  restart              stop then start
  status               show PID/listener and authenticated health
  check                verify auth/characters/world through service account
  query DATABASE SQL   execute SQL as the restricted TrinityCore account
  import DATABASE FILE import a SQL file as the restricted TrinityCore account
TXT
    ;;
esac
