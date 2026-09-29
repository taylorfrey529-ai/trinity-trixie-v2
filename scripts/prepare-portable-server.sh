#!/usr/bin/env bash
set -euo pipefail

WS="${WOW_WORKSPACE:-/mnt/data/WoW.ChromieCraft}"
RT="$WS/runtime/server"
TRINITY="$RT/trinity"
MDB="$RT/mariadb"
STATE="$WS/state/server"
DBSTATE="$WS/state/mariadb"
DATA="$WS/state/data"
LOGS="$WS/logs"
SECRETS="$STATE/db.env"
DB_MARKER="$STATE/.database-prepared"
REALM_NAME="${WOW_REALM_NAME:-WoW.ChromieCraft Trinity}"

mkdir -p "$STATE" "$DBSTATE" "$DATA" "$LOGS"
chmod 700 "$STATE" "$DBSTATE"

for f in "$TRINITY/bin/authserver" "$TRINITY/bin/worldserver" "$MDB/bin/mariadbd" "$MDB/bin/mariadb"; do
  [[ -x "$f" ]] || { echo "missing runtime executable: $f" >&2; exit 2; }
done

find_conf_dist() {
  local name=$1 found
  found="$(find "$TRINITY" -type f -name "$name.conf.dist" -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]] || { echo "missing $name.conf.dist under $TRINITY" >&2; exit 3; }
  printf '%s\n' "$found"
}

if [[ ! -f "$SECRETS" ]]; then
  umask 077
  db_pass="$(openssl rand -hex 24)"
  cat > "$SECRETS" <<ENV
TRINITY_DB_USER=trinity
TRINITY_DB_PASSWORD=$db_pass
ENV
  chmod 600 "$SECRETS"
fi
# shellcheck disable=SC1090
source "$SECRETS"

sql_root="$TRINITY/source/sql"
auth_sql="$sql_root/base/auth_database.sql"
char_sql="$sql_root/base/characters_database.sql"
tdb_sql="$(find "$TRINITY/tdb" -maxdepth 1 -type f -name 'TDB_full_world_335.*.sql' -print -quit 2>/dev/null || true)"
for f in "$auth_sql" "$char_sql" "$tdb_sql"; do
  [[ -f "$f" ]] || { echo "missing database seed: $f" >&2; exit 4; }
done

install_db=""
for candidate in "$MDB/scripts/mariadb-install-db" "$MDB/bin/mariadb-install-db"; do
  [[ -x "$candidate" ]] && { install_db="$candidate"; break; }
done
[[ -n "$install_db" ]] || { echo "missing mariadb-install-db" >&2; exit 5; }

socket="$DBSTATE/prepare.sock"
pidfile="$DBSTATE/prepare.pid"
errlog="$LOGS/mariadb-prepare.log"

stop_temp_db() {
  if [[ -S "$socket" ]]; then
    "$MDB/bin/mariadb-admin" --no-defaults --protocol=socket --socket="$socket" -uroot shutdown >/dev/null 2>&1 || true
  fi
  if [[ -f "$pidfile" ]]; then
    p="$(cat "$pidfile" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null || true
  fi
  rm -f "$socket" "$pidfile"
}
trap stop_temp_db EXIT

if [[ ! -d "$DBSTATE/data/mysql" ]]; then
  mkdir -p "$DBSTATE/data"
  args=(--no-defaults --basedir="$MDB" --datadir="$DBSTATE/data" --auth-root-authentication-method=normal --skip-test-db)
  if [[ $(id -u) -eq 0 ]]; then args+=(--user=root); fi
  "$install_db" "${args[@]}" >"$LOGS/mariadb-install-db.log" 2>&1
fi

stop_temp_db
server_args=(
  --no-defaults
  --basedir="$MDB"
  --datadir="$DBSTATE/data"
  --socket="$socket"
  --pid-file="$pidfile"
  --log-error="$errlog"
  --skip-networking
  --skip-name-resolve
)
if [[ $(id -u) -eq 0 ]]; then server_args+=(--user=root); fi
nohup "$MDB/bin/mariadbd" "${server_args[@]}" >"$LOGS/mariadb-prepare.stdout.log" 2>&1 &

for _ in $(seq 1 120); do
  [[ -S "$socket" ]] && "$MDB/bin/mariadb-admin" --no-defaults --protocol=socket --socket="$socket" -uroot ping >/dev/null 2>&1 && break
  sleep 0.25
done
"$MDB/bin/mariadb-admin" --no-defaults --protocol=socket --socket="$socket" -uroot ping >/dev/null 2>&1 || {
  tail -100 "$errlog" >&2 || true
  exit 6
}

mysql_root=("$MDB/bin/mariadb" --no-defaults --protocol=socket --socket="$socket" -uroot)

if [[ ! -f "$DB_MARKER" ]]; then
  escaped_pass="${TRINITY_DB_PASSWORD//\'/\'\'}"
  "${mysql_root[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS auth DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS characters DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS world DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'trinity'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
ALTER USER 'trinity'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
GRANT ALL PRIVILEGES ON auth.* TO 'trinity'@'127.0.0.1';
GRANT ALL PRIVILEGES ON characters.* TO 'trinity'@'127.0.0.1';
GRANT ALL PRIVILEGES ON world.* TO 'trinity'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  "${mysql_root[@]}" auth < "$auth_sql"
  "${mysql_root[@]}" characters < "$char_sql"
  "${mysql_root[@]}" world < "$tdb_sql"
  touch "$DB_MARKER"
fi

realm_name_sql="${REALM_NAME//\'/\'\'}"
"${mysql_root[@]}" auth <<SQL
INSERT INTO realmlist (id,name,address,localAddress,localSubnetMask,port,gamebuild)
VALUES (1,'${realm_name_sql}','127.0.0.1','127.0.0.1','255.255.255.0',8085,12340)
ON DUPLICATE KEY UPDATE name=VALUES(name),address=VALUES(address),localAddress=VALUES(localAddress),localSubnetMask=VALUES(localSubnetMask),port=VALUES(port),gamebuild=VALUES(gamebuild);
SQL

world_dist="$(find_conf_dist worldserver)"
auth_dist="$(find_conf_dist authserver)"
cp "$world_dist" "$STATE/worldserver.conf"
cp "$auth_dist" "$STATE/authserver.conf"
chmod 600 "$STATE/worldserver.conf" "$STATE/authserver.conf"

python3 - "$STATE/worldserver.conf" "$STATE/authserver.conf" "$TRINITY" "$MDB" "$DATA" "$LOGS" "$TRINITY_DB_USER" "$TRINITY_DB_PASSWORD" <<'PY'
import re, sys
world, auth, trinity, mdb, data, logs, user, password = sys.argv[1:]

def patch(path, replacements):
    text = open(path, encoding='utf-8').read()
    for key, value in replacements.items():
        pattern = rf'(?m)^{re.escape(key)}\s*=.*$'
        new = f'{key} = {value}'
        text, count = re.subn(pattern, new, text, count=1)
        if count != 1:
            raise SystemExit(f'config key not found: {key} in {path}')
    open(path, 'w', encoding='utf-8').write(text)

source = trinity + '/source'
mysql = mdb + '/bin/mariadb'
conn_auth = f'"127.0.0.1;3306;{user};{password};auth"'
conn_world = f'"127.0.0.1;3306;{user};{password};world"'
conn_chars = f'"127.0.0.1;3306;{user};{password};characters"'
patch(world, {
    'RealmID': '1',
    'DataDir': f'"{data}"',
    'LogsDir': f'"{logs}"',
    'LoginDatabaseInfo': conn_auth,
    'WorldDatabaseInfo': conn_world,
    'CharacterDatabaseInfo': conn_chars,
    'WorldServerPort': '8085',
    'BindIP': '"127.0.0.1"',
    'SourceDirectory': f'"{source}"',
    'MySQLExecutable': f'"{mysql}"',
})
patch(auth, {
    'LogsDir': f'"{logs}"',
    'RealmServerPort': '3724',
    'BindIP': '"127.0.0.1"',
    'LoginDatabaseInfo': conn_auth,
    'SourceDirectory': f'"{source}"',
    'MySQLExecutable': f'"{mysql}"',
})
PY

stop_temp_db
trap - EXIT

echo "database=prepared"
echo "realm=prepared id=1 build=12340"
echo "configs=prepared path=$STATE"
if [[ -d "$DATA/dbc" && -d "$DATA/maps" && -d "$DATA/vmaps" && -d "$DATA/mmaps" ]]; then
  echo "client_data=present"
else
  echo "client_data=missing next=run scripts/extract-portable-server-data.sh" >&2
fi
