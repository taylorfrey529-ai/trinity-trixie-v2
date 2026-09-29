#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${1:-$ROOT/native/trinitycore-335-f5f9bac-recovery-bundle.tar.gz}"
DEST="$ROOT/native/recovery-bundle"
[[ -f "$BUNDLE" ]] || { echo "Missing bundle: $BUNDLE" >&2; exit 2; }
mkdir -p "$DEST"
if [[ -n "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "Refusing to overwrite non-empty destination: $DEST" >&2
  exit 3
fi
tar -tzf "$BUNDLE" >/dev/null
tar -xzf "$BUNDLE" -C "$DEST"
(
  cd "$DEST"
  sha256sum -c evidence/SHA256SUMS
)
for bin in authserver worldserver mapextractor vmap4extractor vmap4assembler mmaps_generator; do
  test -x "$DEST/install/bin/$bin"
done
echo "Installed and verified recovery bundle: $DEST"
echo "Next gate: configure database/runtime paths and extract client map/vmap/mmaps data."
