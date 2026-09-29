#!/usr/bin/env bash
set -euo pipefail

WS="${WOW_WORKSPACE:-/mnt/data/WoW.ChromieCraft}"
ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || {
  echo "usage: $0 /path/to/trinity-335-portable-linux-x64.tar.zst" >&2
  exit 2
}

if [[ -f "$ARCHIVE.sha256" ]]; then
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256")
fi

mkdir -p "$WS/runtime" "$WS/logs"
stage="$(mktemp -d "$WS/runtime/.server-install.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

tar --zstd -xf "$ARCHIVE" -C "$stage"
for f in   "$stage/trinity/bin/authserver"   "$stage/trinity/bin/worldserver"   "$stage/mariadb/bin/mariadbd"   "$stage/mariadb/bin/mariadb"   "$stage/RUNTIME-MANIFEST.env"
do
  [[ -e "$f" ]] || { echo "artifact missing required path: $f" >&2; exit 3; }
done

new="$WS/runtime/server.new.$$"
rm -rf "$new"
mv "$stage" "$new"
trap - EXIT

if [[ -e "$WS/runtime/server" ]]; then
  prev="$WS/runtime/server.prev.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$WS/runtime/server" "$prev"
  echo "previous_runtime=$prev"
fi
mv "$new" "$WS/runtime/server"
echo "server_runtime=installed path=$WS/runtime/server"
cat "$WS/runtime/server/RUNTIME-MANIFEST.env"
