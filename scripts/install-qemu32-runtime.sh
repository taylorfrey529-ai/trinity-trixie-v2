#!/usr/bin/env bash
set -euo pipefail

TRANSFER_DIR="${1:?usage: install-qemu32-runtime.sh <transfer-dir> [workspace-root]}"
WORKSPACE="${2:-/mnt/data/workspace/wow-private-server}"
MANIFEST="$TRANSFER_DIR/manifest.json"
STAGE="$WORKSPACE/.qemu32-install-stage"
RUNTIME="$WORKSPACE/runtime"

test -f "$MANIFEST"
mkdir -p "$WORKSPACE" "$RUNTIME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

python3 - "$TRANSFER_DIR" "$MANIFEST" "$STAGE" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

transfer = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
stage = pathlib.Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text())
parts = manifest["parts"]
expected_whole = manifest["logical_sha256"]
expected_size = int(manifest["logical_size"])

whole = hashlib.sha256()
total = 0

proc = subprocess.Popen(
    ["tar", "--zstd", "-xf", "-", "-C", str(stage)],
    stdin=subprocess.PIPE,
)
assert proc.stdin is not None

for part in parts:
    path = transfer / part["name"]
    if not path.is_file():
        raise SystemExit(f"missing part: {path}")
    data_hash = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            data_hash.update(chunk)
            whole.update(chunk)
            total += len(chunk)
            size += len(chunk)
            proc.stdin.write(chunk)
    if size != int(part["size"]):
        raise SystemExit(f"size mismatch: {path.name}")
    if data_hash.hexdigest() != part["sha256"]:
        raise SystemExit(f"sha256 mismatch: {path.name}")

proc.stdin.close()
rc = proc.wait()
if rc != 0:
    raise SystemExit(f"tar extraction failed: {rc}")
if total != expected_size:
    raise SystemExit(f"logical size mismatch: {total} != {expected_size}")
if whole.hexdigest() != expected_whole:
    raise SystemExit(f"logical sha256 mismatch: {whole.hexdigest()} != {expected_whole}")

runtime = stage / "runtime"
required = [
    runtime / "qemu-i386-static",
    runtime / "qemu-wine32-bin" / "wine",
    runtime / "qemu-wine32-bin" / "wineserver",
    runtime / "wine-11.18-staging-x86-qemu",
    runtime / "wine32-qemu-rootfs",
]
for path in required:
    if not path.exists():
        raise SystemExit(f"required runtime path missing: {path}")

print(f"logical_size={total}")
print(f"logical_sha256={whole.hexdigest()}")
print("qemu32_stage=PASS")
PY

for name in qemu-i386-static qemu-wine32-bin wine-11.18-staging-x86-qemu wine32-qemu-rootfs; do
  test -e "$STAGE/runtime/$name"
  rm -rf "$RUNTIME/$name.new"
  mv "$STAGE/runtime/$name" "$RUNTIME/$name.new"
done

for name in qemu-i386-static qemu-wine32-bin wine-11.18-staging-x86-qemu wine32-qemu-rootfs; do
  if [ -e "$RUNTIME/$name" ]; then
    rm -rf "$RUNTIME/$name.previous"
    mv "$RUNTIME/$name" "$RUNTIME/$name.previous"
  fi
  mv "$RUNTIME/$name.new" "$RUNTIME/$name"
done

rm -rf "$STAGE"

test -x "$RUNTIME/qemu-i386-static"
test -x "$RUNTIME/qemu-wine32-bin/wine"
test -x "$RUNTIME/qemu-wine32-bin/wineserver"

echo "qemu32_install=PASS"
