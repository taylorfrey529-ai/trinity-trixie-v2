#!/usr/bin/env bash
set -euo pipefail

WS="${WOW_WORKSPACE:-/mnt/data/WoW.ChromieCraft}"
CLIENT="$WS/client/ChromieCraft_3.3.5a"
TRINITY="$WS/runtime/server/trinity"
DATA="$WS/state/data"
LOGS="$WS/logs"

[[ -f "$CLIENT/Wow.exe" && -d "$CLIENT/Data" ]] || { echo "ChromieCraft client is not rehydrated under $CLIENT" >&2; exit 2; }
for tool in mapextractor vmap4extractor vmap4assembler mmaps_generator; do
  [[ -x "$TRINITY/bin/$tool" ]] || { echo "missing TrinityCore extraction tool: $TRINITY/bin/$tool" >&2; exit 3; }
done

stage="$(mktemp -d "$WS/state/.data-extract.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
ln -s "$CLIENT/Data" "$stage/Data"
ln -s "$CLIENT/Wow.exe" "$stage/Wow.exe"

(
  cd "$stage"
  "$TRINITY/bin/mapextractor" >"$LOGS/mapextractor.log" 2>&1
  "$TRINITY/bin/vmap4extractor" >"$LOGS/vmap4extractor.log" 2>&1
  "$TRINITY/bin/vmap4assembler" Buildings vmaps >"$LOGS/vmap4assembler.log" 2>&1
  "$TRINITY/bin/mmaps_generator" >"$LOGS/mmaps-generator.log" 2>&1
)

for d in dbc maps vmaps mmaps; do
  [[ -d "$stage/$d" ]] || { echo "extraction missing output: $d" >&2; exit 4; }
done

mkdir -p "$DATA.new.$$"
for d in dbc maps vmaps mmaps; do mv "$stage/$d" "$DATA.new.$$/$d"; done
if [[ -d "$DATA" ]]; then mv "$DATA" "$DATA.prev.$(date -u +%Y%m%dT%H%M%SZ)"; fi
mv "$DATA.new.$$" "$DATA"
trap - EXIT
rm -rf "$stage"

echo "server_data=prepared path=$DATA"
