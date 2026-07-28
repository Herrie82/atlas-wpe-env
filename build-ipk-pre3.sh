#!/bin/bash
# Build a complete, installable HP Pre 3 Atlas ipk from an existing TouchPad ("tenderloin") ipk's engine
# bundle (same ABI) + the on-device fixes found during Pre 3 bring-up baked in. Produces a drop that
# installs clean via Preware with no manual repair. See PRE3-PORT.md and the pre3-graphics-bringup notes.
#
# Bakes in, over the reused deviceroot:
#   - pre3-lowmem app front-end (low-memory profile + phone CSS)
#   - libaffinity.so.0            (webOS-3.0.5 system lib, absent on 2.2.4)          -> $D/lib
#   - rebuilt BrowserServer-atlas (viewport fix: BPWPE_SCREEN_W/H)                    -> $D/
#   - patched libepoxy.so.0       (EGL 1.4 version clamp for Adreno 205)              -> $D/lib
#   - WPEWebProcess --add-needed libEGL.so.1 (EGL subdriver global symbol scope)      -> $D/libexec/...
#   - device-profile-pre3 (RAM/core/buffer/screen tuning) + wrapper sources it, minus -platform (Qt4)
#   - postinst SELF-HEAL: rename any files whose name got the octal mode appended by 2.2.4 busybox-tar
# Result: $OUT/org.webosports.app.atlas_<ver>_pre3.ipk
set -euo pipefail

ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$ENV_DIR")}"
TP_IPK="${TP_IPK:-/home/herrie/webos/wpe/ipk-build/org.webosports.app.atlas_0.9.6_all.ipk}"
APPSRC="${APPSRC:-$REPOS/atlas-browser-app}"
PROFILE="${PROFILE:-$ENV_DIR/ipk-build/pull/device-profile-pre3}"
OUT="${OUT:-/home/herrie/webos/Pre3/atlas-pre3-build}"
# engine-fix artifacts (overridable)
BS_ATLAS="${BS_ATLAS:-/home/herrie/webos/wpe/browserserver-wpe/obj/BrowserServer-atlas}"
LIBEPOXY="${LIBEPOXY:-/home/herrie/webos/wpe/build/libepoxy-1.5.10/_b/src/libepoxy.so.0.0.0}"
LIBAFFINITY="${LIBAFFINITY:-/home/herrie/webos/touchpad-kernel/doctor305/nova-cust-image-topaz.rootfs/usr/lib/libaffinity.so.0.0.0}"
APPNAME=org.webosports.app.atlas

for f in "$TP_IPK" "$APPSRC/appinfo.json" "$PROFILE" "$BS_ATLAS" "$LIBEPOXY" "$LIBAFFINITY"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
command -v patchelf >/dev/null || { echo "patchelf required" >&2; exit 1; }
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$APPSRC/appinfo.json" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1); : "${VER:=0.9.7}"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "=== 1. unpack TouchPad ipk (reused engine) ==="
( cd "$W" && ar x "$TP_IPK" && mkdir data ctl && tar xzf data.tar.gz -C data && tar xzf control.tar.gz -C ctl )
APP="$W/data/usr/palm/applications/$APPNAME"; D="$APP/deviceroot/wpe-252"
[ -d "$D" ] || { echo "no engine deviceroot" >&2; exit 1; }

echo "=== 2. pre3-lowmem app front-end ==="
for item in appinfo.json css db depends.js index.html source images icon-1024x1024.png icon-256x256.png icon-48x48.png icon-64x64.png icon.png; do
  rm -rf "$APP/${item:?}"; [ -e "$APPSRC/$item" ] && cp -a "$APPSRC/$item" "$APP/"
done

echo "=== 3. bake engine fixes ==="
install -m644 "$LIBAFFINITY"        "$D/lib/libaffinity.so.0"
install -m755 "$BS_ATLAS"           "$D/BrowserServer-atlas"
install -m644 "$LIBEPOXY"           "$D/lib/libepoxy.so.0"
# WPEWebProcess: add libEGL.so.1 as a direct NEEDED so the Adreno subdriver's eglSubDriverWait resolves.
patchelf --add-needed libEGL.so.1 "$D/libexec/wpe-webkit-2.0/WPEWebProcess"
echo "  WPEWebProcess NEEDED libEGL: $(readelf -d "$D/libexec/wpe-webkit-2.0/WPEWebProcess" | grep -c 'libEGL.so.1')"

echo "=== 4. device-profile + wrapper (source it, drop Qt5 -platform) ==="
cp -a "$PROFILE" "$APP/deviceroot/atlas/device-profile"
WRAP="$APP/deviceroot/atlas/BrowserServer"
grep -q 'device-profile' "$WRAP" || awk '/^exec .*BrowserServer-atlas/ && !d { print "[ -r \"$ATLAS/device-profile\" ] && . \"$ATLAS/device-profile\""; d=1 } {print}' "$WRAP" > "$WRAP.n" && mv "$WRAP.n" "$WRAP"
sed -i 's/ -platform Minimal//' "$WRAP"; chmod 755 "$WRAP"

echo "=== 5. postinst self-heal (2.2.4 busybox-tar mode-in-name corruption) ==="
PI="$W/ctl/postinst"
if ! grep -q 'busybox-tar mode-in-name' "$PI"; then
  # insert the repair right after DR= is defined, before anything uses the files
  awk '{print} /^DR=/ && !d { print ""; print "# self-heal: webOS 2.2.4 ipkg/busybox-tar can append a file'\''s octal mode to its name"; print "# (libX.so -> libX.so0000775). Strip the trailing 7-digit mode so sonames resolve."; print "for _f in $(find \"$DR\" -regex \".*0000[0-7][0-7][0-7]\" 2>/dev/null); do mv \"$_f\" \"${_f%???????}\" 2>/dev/null; done"; d=1 }' "$PI" > "$PI.n" && mv "$PI.n" "$PI"; chmod 755 "$PI"
fi

echo "=== 6. control ==="
sed -i -E "s/^Version: .*/Version: $VER/" "$W/ctl/control"
sed -i -E "s/for webOS \(HP TouchPad\)\./for webOS (HP Pre 3, 512MB — low-memory + graphics bring-up)./" "$W/ctl/control"

echo "=== 7. repack (ustar: least busybox mangling; postinst self-heals the rest) ==="
mkdir -p "$OUT"
( cd "$W/data" && tar --format=ustar -czf "$W/data.tar.gz" --owner=0 --group=0 ./* )
( cd "$W/ctl"  && tar --format=ustar -czf "$W/control.tar.gz" --owner=0 --group=0 ./* )
echo "2.0" > "$W/debian-binary"
IPK="$OUT/${APPNAME}_${VER}_pre3.ipk"; rm -f "$IPK"
( cd "$W" && ar rc "$IPK" debian-binary control.tar.gz data.tar.gz )
echo "=== done: $IPK  ($(stat -c%s "$IPK") bytes) ==="
