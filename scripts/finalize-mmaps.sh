#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/native/recovery-bundle"
DATA="$SERVER/data"
LOG="$ROOT/native/mmaps-generator.log"
PIDFILE="$ROOT/native/mmaps-generator.pid"
MARKER="$DATA/.extraction-complete"

pid=""
if [[ -f "$PIDFILE" ]]; then
  pid="$(tr -d '[:space:]' < "$PIDFILE" 2>/dev/null || true)"
fi
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  progress="$(awk '/^[0-9]+% /{p=$1} END{print p+0}' "$LOG" 2>/dev/null || echo 0)"
  echo "mmaps still running: pid=$pid progress=${progress}%" >&2
  exit 3
fi

[[ -s "$LOG" ]] || { echo "Missing mmaps log: $LOG" >&2; exit 2; }
progress="$(awk '/^[0-9]+% /{p=$1} END{print p+0}' "$LOG")"
[[ "$progress" -ge 99 ]] || { echo "mmaps log did not reach terminal progress (last=${progress}%)" >&2; exit 4; }
last_line="$(awk 'NF{line=$0} END{print line}' "$LOG")"
[[ "$last_line" == *'Writing to file...'* ]] || { echo "mmaps log does not end after a completed tile write: $last_line" >&2; exit 4; }

if grep -Ein '(^|[^a-z])(fatal|assert|exception)([^a-z]|$)|failed to|error:' "$LOG" >/tmp/mmaps-finalize-errors.$$ 2>/dev/null; then
  cat /tmp/mmaps-finalize-errors.$$ >&2
  rm -f /tmp/mmaps-finalize-errors.$$
  echo "mmaps log contains fatal/error indicators" >&2
  exit 5
fi
rm -f /tmp/mmaps-finalize-errors.$$

for d in dbc maps vmaps mmaps; do
  [[ -d "$DATA/$d" ]] || { echo "Missing data directory: $DATA/$d" >&2; exit 6; }
done

dbc_count="$(find "$DATA/dbc" -type f | wc -l)"
map_count="$(find "$DATA/maps" -type f | wc -l)"
vmap_count="$(find "$DATA/vmaps" -type f | wc -l)"
mmap_count="$(find "$DATA/mmaps" -type f | wc -l)"

[[ "$dbc_count" -ge 200 ]] || { echo "DBC count too small: $dbc_count" >&2; exit 7; }
[[ "$map_count" -ge 5000 ]] || { echo "map count too small: $map_count" >&2; exit 7; }
[[ "$vmap_count" -ge 10000 ]] || { echo "vmap count too small: $vmap_count" >&2; exit 7; }
mmap_headers="$(find "$DATA/mmaps" -maxdepth 1 -type f -name '*.mmap' | wc -l)"
mmap_tiles="$(find "$DATA/mmaps" -maxdepth 1 -type f -name '*.mmtile' | wc -l)"
[[ "$mmap_count" -ge 3000 ]] || { echo "mmap file count too small: $mmap_count" >&2; exit 7; }
[[ "$mmap_headers" -ge 90 ]] || { echo "mmap header count too small: $mmap_headers" >&2; exit 7; }
[[ "$mmap_tiles" -ge 3000 ]] || { echo "mmap tile count too small: $mmap_tiles" >&2; exit 7; }

binary="$SERVER/install/bin/mmaps_generator"
binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
{
  echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "core_commit=f5f9bac4fa74da42e2dce419309362aede578e9d"
  echo "client_build=3.3.5a.12340"
  echo "mmaps_generator_sha256=$binary_sha"
  echo "dbc_files=$dbc_count"
  echo "map_files=$map_count"
  echo "vmap_files=$vmap_count"
  echo "mmap_files=$mmap_count"
  echo "mmap_headers=$mmap_headers"
  echo "mmap_tiles=$mmap_tiles"
  echo "terminal_progress=$progress"
  echo "completion_evidence=generator_exited_no_errors_final_tile_write"
} > "$MARKER.tmp"
mv "$MARKER.tmp" "$MARKER"
sync "$MARKER" 2>/dev/null || sync
cat "$MARKER"
