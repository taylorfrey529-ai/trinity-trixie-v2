#!/usr/bin/env bash
set -euo pipefail

sudo dpkg --add-architecture i386
sudo install -d -m 0755 /etc/apt/keyrings
wget -qO- https://dl.winehq.org/wine-builds/winehq.key | sudo tee /etc/apt/keyrings/winehq-archive.key >/dev/null
wget -qO- https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources | sudo tee /etc/apt/sources.list.d/winehq-noble.sources >/dev/null
sudo apt-get update

VERSION="$(apt-cache madison wine-staging-i386:i386 | awk '$3 ~ /^11\.18~noble/ {print $3; exit}')"
test -n "$VERSION"
echo "WINEHQ_VERSION=$VERSION" >> "$GITHUB_ENV"

sudo apt-get install -y --no-install-recommends   qemu-user-static xvfb xauth x11-utils zstd   "wine-staging-i386:i386=$VERSION"   "wine-staging-amd64=$VERSION"   "wine-staging=$VERSION"

OUT="$RUNNER_TEMP/qemu32"
RUNTIME="$OUT/runtime"
WINE_OUT="$RUNTIME/wine-11.18-staging-x86-qemu"
ROOTFS="$RUNTIME/wine32-qemu-rootfs"
mkdir -p "$WINE_OUT/lib/wine" "$WINE_OUT/bin" "$RUNTIME/qemu-wine32-bin"
mkdir -p "$ROOTFS/lib" "$ROOTFS/usr/lib" "$ROOTFS/usr/share" "$ROOTFS/etc"

I386_UNIX="$(find /opt/wine-staging -type d -path '*/wine/i386-unix' -print -quit)"
I386_WINDOWS="$(find /opt/wine-staging -type d -path '*/wine/i386-windows' -print -quit)"
test -n "$I386_UNIX"
test -n "$I386_WINDOWS"

test -n "$I386_UNIX"
test -n "$I386_WINDOWS"
cp -a "$I386_UNIX" "$WINE_OUT/lib/wine/"
cp -a "$I386_WINDOWS" "$WINE_OUT/lib/wine/"
if [[ -d /opt/wine-staging/share ]]; then cp -a /opt/wine-staging/share "$WINE_OUT/"; fi

REAL_WINE="$WINE_OUT/lib/wine/i386-unix/wine"
test -x "$REAL_WINE"
file "$REAL_WINE" | grep -q 'ELF 32-bit'

NATIVE_SERVER="/opt/wine-staging/bin/wineserver"
test -x "$NATIVE_SERVER"
cp -a "$NATIVE_SERVER" "$WINE_OUT/bin/wineserver.native"

cp -a /usr/bin/qemu-i386-static "$RUNTIME/qemu-i386-static"
cp -a /lib/i386-linux-gnu "$ROOTFS/lib/"
cp -a /usr/lib/i386-linux-gnu "$ROOTFS/usr/lib/"
cp -aL /lib/ld-linux.so.2 "$ROOTFS/lib/ld-linux.so.2"

if [[ -d /usr/share/glvnd ]]; then cp -a /usr/share/glvnd "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/fonts ]]; then cp -a /usr/share/fonts "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/fontconfig ]]; then cp -a /usr/share/fontconfig "$ROOTFS/usr/share/"; fi
if [[ -d /usr/share/X11 ]]; then cp -a /usr/share/X11 "$ROOTFS/usr/share/"; fi
if [[ -d /etc/fonts ]]; then cp -a /etc/fonts "$ROOTFS/etc/"; fi

cat > "$RUNTIME/qemu-wine32-bin/wine" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WINE_ROOT="$RUNTIME/wine-11.18-staging-x86-qemu"
export WINELOADER="$WINE_ROOT/lib/wine/i386-unix/wine"
export WINELOADERNOEXEC=1
exec "$RUNTIME/qemu-i386-static" -L "$RUNTIME/wine32-qemu-rootfs" -R '0x100000000' "$WINELOADER" "$@"
SH
chmod 0755 "$RUNTIME/qemu-wine32-bin/wine"

cat > "$RUNTIME/qemu-wine32-bin/wineserver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
exec "$RUNTIME/wine-11.18-staging-x86-qemu/bin/wineserver.native" "$@"
SH
chmod 0755 "$RUNTIME/qemu-wine32-bin/wineserver"

grep -q -- "-R '0x100000000'" "$RUNTIME/qemu-wine32-bin/wine"
test -x "$WINE_OUT/lib/wine/i386-unix/wine-preloader"
test -x "$WINE_OUT/lib/wine/i386-unix/wine"
test -x "$WINE_OUT/bin/wineserver.native"
file "$WINE_OUT/lib/wine/i386-unix/wine" | grep -q 'ELF 32-bit'
test -e "$ROOTFS/lib/ld-linux.so.2"

export WINE_ROOT="$WINE_OUT"
export WINE="$RUNTIME/qemu-wine32-bin/wine"
export WINESERVER="$RUNTIME/qemu-wine32-bin/wineserver"
export WINEPREFIX="$RUNNER_TEMP/qemu32-prefix"
export WINEARCH=win32
export WINELOADER="$WINE_OUT/lib/wine/i386-unix/wine"
export WINEDLLOVERRIDES='mscoree,mshtml,winegstreamer='
mkdir -p "$WINEPREFIX"
export LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH="$ROOTFS/usr/lib/i386-linux-gnu/dri"

Xvfb :99 -screen 0 1280x720x24 -nolisten tcp >"$RUNNER_TEMP/xvfb.log" 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
export DISPLAY=:99
for _ in $(seq 1 50); do
  xdpyinfo -display :99 >/dev/null 2>&1 && break
  sleep 0.1
done
xdpyinfo -display :99 >/dev/null

echo "=== qemu32 loader diagnostics ==="
file "$RUNTIME/qemu-i386-static" "$WINELOADER" "$ROOTFS/lib/ld-linux.so.2"
"$RUNTIME/qemu-i386-static" -L "$ROOTFS" "$ROOTFS/lib/ld-linux.so.2" --list "$WINELOADER" || true

set +e
"$RUNTIME/qemu-i386-static" -L "$ROOTFS" "$WINELOADER" --version
RC_NO_RESERVE=$?
"$RUNTIME/qemu-i386-static" -L "$ROOTFS" -R '0x100000000' "$WINELOADER" --version
RC_RESERVE=$?
set -e

echo "qemu32_no_reserve_rc=$RC_NO_RESERVE"
echo "qemu32_reserve_rc=$RC_RESERVE"
test "$RC_NO_RESERVE" -eq 0
test "$RC_RESERVE" -eq 0

"$WINE" --version
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
import hashlib, json, os
from pathlib import Path

src=Path("transfer/qemu32-wine1118-runtime.tar.zst")
chunk=180*1024*1024
whole=hashlib.sha256()
parts=[]
with src.open("rb") as f:
    i=0
    while True:
        data=f.read(chunk)
        if not data:
            break
        whole.update(data)
        name=f"payload.part.{i:03d}"
        path=Path("transfer")/name
        path.write_bytes(data)
        parts.append({"index":i,"name":name,"size":len(data),"sha256":hashlib.sha256(data).hexdigest()})
        i+=1

manifest={
    "schema_version":1,
    "logical_name":src.name,
    "logical_size":src.stat().st_size,
    "logical_sha256":whole.hexdigest(),
    "wine_version":"11.18-staging",
    "winehq_version":os.environ["WINEHQ_VERSION"],
    "mode":"qemu32",
    "guest_va_reservation":"0x100000000",
    "selftest":"PASS",
    "parts":parts,
}
Path("transfer/manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
print(json.dumps(manifest,indent=2))
assert 1 <= len(parts) <= 5
PY

rm "$GITHUB_WORKSPACE/transfer/qemu32-wine1118-runtime.tar.zst"
