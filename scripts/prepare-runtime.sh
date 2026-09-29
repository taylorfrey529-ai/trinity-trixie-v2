#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE_DIR="$ROOT/runtime/wine-11.18-staging-amd64-wow64"
DXVK_DIR="$ROOT/runtime/dxvk-3.1.1"
if [[ ! -x "$WINE_DIR/bin/wine" ]]; then
  src="${WOW_WINE_ARCHIVE:-/mnt/data/wine-11.18-staging-amd64-wow64.tar.xz}"
  [[ -f "$src" ]] || { echo "missing Wine warm-layer archive: $src" >&2; exit 2; }
  tar -xJf "$src" -C "$ROOT/runtime"
fi
if [[ ! -d "$DXVK_DIR" ]]; then
  src="${WOW_DXVK_ARCHIVE:-/mnt/data/dxvk-3.1.1.tar.gz}"
  [[ -f "$src" ]] || { echo "missing DXVK warm-layer archive: $src" >&2; exit 2; }
  tar -xzf "$src" -C "$ROOT/runtime"
fi
printf 'wine=%s\ndxvk=%s\n' "$WINE_DIR" "$DXVK_DIR"
