#!/usr/bin/env bash
set -euo pipefail

WINE_VERSION=11.18
WINEHQ_SERIES=11.x
WINE_SOURCE_URL="https://dl.winehq.org/wine/source/$WINEHQ_SERIES/wine-$WINE_VERSION.tar.xz"

sudo dpkg --add-architecture i386
sudo install -d -m 0755 /etc/apt/keyrings
wget -qO- https://dl.winehq.org/wine-builds/winehq.key | sudo tee /etc/apt/keyrings/winehq-archive.key >/dev/null
wget -qO- https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources | sudo tee /etc/apt/sources.list.d/winehq-noble.sources >/dev/null
sudo apt-get update

VERSION="$(apt-cache madison wine-staging-i386:i386 | awk '$3 ~ /^11\.18~noble/ {print $3; exit}')"
test -n "$VERSION"
echo "WINEHQ_VERSION=$VERSION" >> "$GITHUB_ENV"

sudo apt-get install -y --no-install-recommends   qemu-user-static xvfb xauth x11-utils zstd   build-essential gcc-multilib g++-multilib libc6-dev-i386 pkg-config bison flex   libfreetype-dev:i386   "wine-staging-i386:i386=$VERSION"   "wine-staging-amd64=$VERSION"   "wine-staging=$VERSION"

OUT="$RUNNER_TEMP/qemu32"
RUNTIME="$OUT/runtime"
WINE_OUT="$RUNTIME/wine-11.18-staging-x86-qemu"
ROOTFS="$RUNTIME/wine32-qemu-rootfs"
QBIN="$RUNTIME/qemu-wine32-bin"

mkdir -p "$WINE_OUT/lib/wine" "$QBIN"
mkdir -p "$ROOTFS/lib" "$ROOTFS/usr/lib" "$ROOTFS/usr/share" "$ROOTFS/etc"

I386_UNIX="$(find /opt/wine-staging -type d -path '*/wine/i386-unix' -print -quit)"
I386_WINDOWS="$(find /opt/wine-staging -type d -path '*/wine/i386-windows' -print -quit)"
test -n "$I386_UNIX"
test -n "$I386_WINDOWS"

cp -a "$I386_UNIX" "$WINE_OUT/lib/wine/"
cp -a "$I386_WINDOWS" "$WINE_OUT/lib/wine/"
if [[ -d /opt/wine-staging/share ]]; then
  cp -a /opt/wine-staging/share "$WINE_OUT/"
fi

REAL_WINE="$WINE_OUT/lib/wine/i386-unix/wine"
test -x "$REAL_WINE"
file "$REAL_WINE" | grep -q 'ELF 32-bit'
mv "$REAL_WINE" "$WINE_OUT/lib/wine/i386-unix/wine.qemu-real"

cp -a /usr/bin/qemu-i386-static "$RUNTIME/qemu-i386-static"
cp -a /lib/i386-linux-gnu "$ROOTFS/lib/"
cp -a /usr/lib/i386-linux-gnu "$ROOTFS/usr/lib/"
cp -aL /lib/ld-linux.so.2 "$ROOTFS/lib/ld-linux.so.2"

if [[ -d /usr/share/glvnd ]]; then cp -a /usr/share/glvnd "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/fonts ]]; then cp -a /usr/share/fonts "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/fontconfig ]]; then cp -a /usr/share/fontconfig "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/X11 ]]; then cp -a /usr/share/X11 "$ROOTFS/usr/share/"; fi
if [[ -d /etc/fonts ]]; then cp -a /etc/fonts "$ROOTFS/etc/"; fi

echo "=== build matching i386 wineserver from Wine $WINE_VERSION source ==="
SRC_TAR="$RUNNER_TEMP/wine-$WINE_VERSION.tar.xz"
SRC_DIR="$RUNNER_TEMP/wine-$WINE_VERSION"
BUILD32="$RUNNER_TEMP/wine-$WINE_VERSION-build32"
wget -qO "$SRC_TAR" "$WINE_SOURCE_URL"
tar -xf "$SRC_TAR" -C "$RUNNER_TEMP"
mkdir -p "$BUILD32"

(
  cd "$BUILD32"
  PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig     "$SRC_DIR/configure" --disable-tests --without-x
  make -j2 server/wineserver
)

REAL_SERVER="$BUILD32/server/wineserver"
test -x "$REAL_SERVER"
file "$REAL_SERVER" | grep -q 'ELF 32-bit'
cp -a "$REAL_SERVER" "$QBIN/wineserver.qemu-real"

cat > "$WINE_OUT/lib/wine/i386-unix/wine" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$(cd "$HERE/../../../.." && pwd)"
exec "$RUNTIME/qemu-i386-static"   -L "$RUNTIME/wine32-qemu-rootfs"   -R '0x100000000'   "$HERE/wine.qemu-real" "$@"
SH
chmod 0755 "$WINE_OUT/lib/wine/i386-unix/wine"

cat > "$QBIN/wine" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
exec "$RUNTIME/wine-11.18-staging-x86-qemu/lib/wine/i386-unix/wine" "$@"
SH
chmod 0755 "$QBIN/wine"

cat > "$QBIN/wineserver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
exec "$RUNTIME/qemu-i386-static"   -L "$RUNTIME/wine32-qemu-rootfs"   -R '0x100000000'   "$RUNTIME/qemu-wine32-bin/wineserver.qemu-real" "$@"
SH
chmod 0755 "$QBIN/wineserver"

# Match the archived September 29 client.sh contract exactly.
require_x() { [[ -x "$1" ]] || { echo "contract_check=FAIL kind=executable path=$1" >&2; exit 1; }; echo "contract_check=PASS kind=executable path=$1"; }
require_e() { [[ -e "$1" ]] || { echo "contract_check=FAIL kind=exists path=$1" >&2; exit 1; }; echo "contract_check=PASS kind=exists path=$1"; }
require_f() { [[ -f "$1" ]] || { echo "contract_check=FAIL kind=file path=$1" >&2; exit 1; }; echo "contract_check=PASS kind=file path=$1"; }
require_grep() { local pattern="$1" path="$2"; grep -q -- "$pattern" "$path" || { echo "contract_check=FAIL kind=grep path=$path pattern=$pattern" >&2; exit 1; }; echo "contract_check=PASS kind=grep path=$path pattern=$pattern"; }

echo "=== qemu32 archived-client contract checks ==="
file "$REAL_SERVER"
require_x "$WINE_OUT/lib/wine/i386-unix/wine-preloader"
require_x "$WINE_OUT/lib/wine/i386-unix/wine.qemu-real"
require_x "$QBIN/wineserver.qemu-real"
require_e "$ROOTFS/lib/ld-linux.so.2"
require_f "$ROOTFS/usr/lib/i386-linux-gnu/libEGL_mesa.so.0"
require_f "$ROOTFS/usr/share/glvnd/egl_vendor.d/50_mesa.json"
require_grep "-R '0x100000000'" "$WINE_OUT/lib/wine/i386-unix/wine"
require_grep "-R '0x100000000'" "$QBIN/wineserver"

echo "=== qemu32 identity ==="
file "$RUNTIME/qemu-i386-static"
file "$WINE_OUT/lib/wine/i386-unix/wine.qemu-real"
file "$QBIN/wineserver.qemu-real"
"$QBIN/wine" --version
"$QBIN/wineserver" --version

export WINE_ROOT="$WINE_OUT"
export WINE="$QBIN/wine"
export WINESERVER="$QBIN/wineserver"
export WINEPREFIX="$RUNNER_TEMP/qemu32-prefix"
export WINEARCH=win32
export WINELOADER="$WINE_OUT/lib/wine/i386-unix/wine"
unset WINELOADERNOEXEC || true
export WINEDLLOVERRIDES='mscoree,mshtml,winegstreamer='
export LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH="$ROOTFS/usr/lib/i386-linux-gnu/dri"
mkdir -p "$WINEPREFIX"

Xvfb :99 -screen 0 1280x720x24 -nolisten tcp >"$RUNNER_TEMP/xvfb.log" 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
export DISPLAY=:99
for _ in $(seq 1 50); do
  xdpyinfo -display :99 >/dev/null 2>&1 && break
  sleep 0.1
done
xdpyinfo -display :99 >/dev/null

"$WINESERVER" -p0
WINEDEBUG=-all "$WINE" wineboot.exe -u
test -f "$WINEPREFIX/system.reg"

OUTTEXT="$(WINEDEBUG=-all "$WINE" cmd.exe /c echo WOW_QEMU32_OK)"
printf '%s\n' "$OUTTEXT"
[[ "$OUTTEXT" == *WOW_QEMU32_OK* ]]

"$WINESERVER" -k || true
echo qemu32_selftest=PASS

mkdir -p "$GITHUB_WORKSPACE/transfer"
tar --zstd -cf "$GITHUB_WORKSPACE/transfer/qemu32-wine1118-runtime.tar.zst" -C "$OUT" runtime

python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

src = Path("transfer/qemu32-wine1118-runtime.tar.zst")
chunk_size = 180 * 1024 * 1024
whole = hashlib.sha256()
parts = []

with src.open("rb") as handle:
    index = 0
    while True:
        data = handle.read(chunk_size)
        if not data:
            break
        whole.update(data)
        name = f"payload.part.{index:03d}"
        path = Path("transfer") / name
        path.write_bytes(data)
        parts.append({
            "index": index,
            "name": name,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
        index += 1

manifest = {
    "schema_version": 1,
    "logical_name": src.name,
    "logical_size": src.stat().st_size,
    "logical_sha256": whole.hexdigest(),
    "wine_version": "11.18-staging",
    "winehq_version": os.environ["WINEHQ_VERSION"],
    "wineserver_source_version": "11.18",
    "mode": "qemu32",
    "guest_va_reservation": "0x100000000",
    "archived_client_contract_sha256": "cd6a2c95adb0390f97e18f0f39d41b6ef2bc603f1434282e20643cbabf855bca",
    "selftest": "PASS",
    "parts": parts,
}
Path("transfer/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
assert 1 <= len(parts) <= 8
PY

rm "$GITHUB_WORKSPACE/transfer/qemu32-wine1118-runtime.tar.zst"
