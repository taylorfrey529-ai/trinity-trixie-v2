#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/native/recovery-bundle"
INSTALL="$SERVER/install"
CONF="$ROOT/config/trinity"
ENV_FILE="$ROOT/.env"
MYSQL_WRAPPER="$ROOT/runtime/bin/mysql-native"

[[ -d "$SERVER" ]] || { echo "Missing installed recovery bundle: $SERVER" >&2; exit 2; }
[[ -x "$INSTALL/bin/authserver" && -x "$INSTALL/bin/worldserver" ]] || { echo "Missing TrinityCore server binaries." >&2; exit 2; }
[[ -f "$INSTALL/etc/authserver.conf.dist" && -f "$INSTALL/etc/worldserver.conf.dist" ]] || { echo "Missing TrinityCore .conf.dist files." >&2; exit 2; }
[[ -x "$MYSQL_WRAPPER" ]] || { echo "Missing MySQL compatibility wrapper: $MYSQL_WRAPPER" >&2; exit 2; }
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
mkdir -p "$CONF" "$SERVER/data" "$SERVER/logs" "$SERVER/run"
cp -f "$INSTALL/etc/authserver.conf.dist" "$CONF/authserver.conf"
cp -f "$INSTALL/etc/worldserver.conf.dist" "$CONF/worldserver.conf"

export ROOT SERVER CONF MYSQL_WRAPPER TC_DB_USER TC_DB_PASSWORD TC_AUTH_DB TC_CHAR_DB TC_WORLD_DB
python3 - <<'PY'
import os, re
from pathlib import Path

root=Path(os.environ['ROOT'])
server=Path(os.environ['SERVER'])
conf=Path(os.environ['CONF'])
mysql=Path(os.environ['MYSQL_WRAPPER'])
user=os.environ['TC_DB_USER']
password=os.environ['TC_DB_PASSWORD']
auth=os.environ['TC_AUTH_DB']; chars=os.environ['TC_CHAR_DB']; world=os.environ['TC_WORLD_DB']

def esc(v:str)->str:
    return v.replace('\\','\\\\').replace('"','\\"')

def set_key(path:Path,key:str,value:str):
    s=path.read_text()
    pat=re.compile(rf'(?m)^[ \t]*{re.escape(key)}[ \t]*=.*$')
    line=f'{key} = {value}'
    s2,n=pat.subn(line,s,count=1)
    if n!=1:
        raise SystemExit(f'expected one {key} in {path}, got {n}')
    path.write_text(s2)

a=conf/'authserver.conf'
w=conf/'worldserver.conf'
login=f'127.0.0.1;3306;{user};{password};{auth}'
worlddb=f'127.0.0.1;3306;{user};{password};{world}'
chardb=f'127.0.0.1;3306;{user};{password};{chars}'

for p in (a,w):
    set_key(p,'BindIP','"127.0.0.1"')
    set_key(p,'SourceDirectory',f'"{esc(str(server/"source"))}"')
    set_key(p,'MySQLExecutable',f'"{esc(str(mysql))}"')

set_key(a,'LogsDir',f'"{esc(str(server/"logs"))}"')
set_key(a,'LoginDatabaseInfo',f'"{esc(login)}"')
set_key(a,'Updates.EnableDatabases','0')

set_key(w,'DataDir',f'"{esc(str(server/"data"))}"')
set_key(w,'LogsDir',f'"{esc(str(server/"logs"))}"')
set_key(w,'LoginDatabaseInfo',f'"{esc(login)}"')
set_key(w,'WorldDatabaseInfo',f'"{esc(worlddb)}"')
set_key(w,'CharacterDatabaseInfo',f'"{esc(chardb)}"')
set_key(w,'Updates.EnableDatabases','7')
set_key(w,'RealmID','1')
PY
chmod 600 "$CONF/authserver.conf" "$CONF/worldserver.conf"

mapfile -t tdbs < <(find "$SERVER/tdb" -maxdepth 1 -type f -name 'TDB_full_world_335*.sql' -print | sort)
if [[ ${#tdbs[@]} -ne 1 ]]; then
  echo "Expected exactly one TDB world SQL file, found ${#tdbs[@]}." >&2
  exit 3
fi
ln -sfn "${tdbs[0]}" "$SERVER/$(basename "${tdbs[0]}")"

echo "TrinityCore configuration generated: $CONF"
echo "Bind addresses: 127.0.0.1 only"
echo "Database updater: $MYSQL_WRAPPER"
echo "Data directory: $SERVER/data"
