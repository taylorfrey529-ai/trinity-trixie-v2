#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/client/ChromieCraft_3.3.5a/Wow.exe"
if [[ -f "$CLIENT" ]]; then
  echo "client=ready path=$CLIENT"
  exit 0
fi
archive="${CHROMIECRAFT_ARCHIVE:-}"
if [[ -z "$archive" ]]; then
  for p in "$ROOT/native/client-transfer/ChromieCraft_3.3.5a.zip" "$ROOT/ChromieCraft_3.3.5a.zip" /mnt/data/ChromieCraft_3.3.5a.zip; do
    [[ -f "$p" ]] && { archive="$p"; break; }
  done
fi
if [[ -n "$archive" ]]; then
  exec "$ROOT/bin/chromiecraft-rehydrate" rehydrate --workspace "$ROOT" --archive "$archive"
fi
echo "client=missing"
echo "Provide an authorized local ChromieCraft_3.3.5a.zip or mount the pre-extracted client at $ROOT/client/ChromieCraft_3.3.5a" >&2
exit 2
