#!/bin/bash
# FULL restore of the Atlas app + WPE engine deviceroot onto the device's cryptofs, after webOS
# garbage-collected the (unregistered) cryptofs app on a reboot. The ROOTFS mods survive that event
# (OpenSSL 1.1 in /usr/lib/ssl11, BrowserAdapterAtlas.so, /etc/event.d/atlas, db8 kinds) — only the
# cryptofs app dir + /var/atlas252 symlink are lost. This reassembles the whole app dir from host
# sources (there is no single deviceroot mirror), tars it, and the companion push step extracts it
# into cryptofs. Layout mirrors what wrapper-BrowserServer expects (see that file's env).
#
#   Assemble:  ./full-restore-atlas.sh            (-> $OUT/atlas-restore.tar.gz)
#              STRIP=0 ./full-restore-atlas.sh    (keep libWPEWebKit unstripped for gdb, ~2x push)
#   Then push: see full-restore-push.sh
set -eu
WPE=/home/herrie/webos/wpe
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"        # TARGET, CC, STAGING(=staging-glibc-252)
S="$STAGING"
ENV=/home/herrie/Documents/GitHub/atlas-wpe-env
GSR=$HOME/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot
OBJ=$WPE/browserserver-wpe/obj
CAM=/home/herrie/webos/touchpad-kernel/doctor305/camera-path-a
APPSRC=/home/herrie/Documents/GitHub/atlas-browser-app   # CURRENT front-end (features+icons), not the stale ipk
ROLESRC=$ENV/roles/org.webosports.browserserver.json     # LunaService role (lost with /var on reset)

APPNAME=org.webosports.app.atlas
CRYPTO_APP=/media/cryptofs/apps/usr/palm/applications/$APPNAME
DEVPATH=$CRYPTO_APP/deviceroot/wpe-252         # real cryptofs path (patchelf interp/rpath: no length limit)
DOSTRIP=${DOSTRIP:-1}

OUT=$WPE/atlas-restore
APP=$OUT/$APPNAME
D=$APP/deviceroot/wpe-252
A=$APP/deviceroot/atlas
rm -rf "$OUT"; mkdir -p "$D/lib" "$D/libexec" "$D/share" "$A"

echo "=== 1. app front-end from CURRENT source (atlas-browser-app) ==="
for item in appinfo.json css db depends.js index.html source images \
            icon-1024x1024.png icon-256x256.png icon-48x48.png icon-64x64.png icon.png; do
  [ -e "$APPSRC/$item" ] && cp -a "$APPSRC/$item" "$APP/"
done

echo "=== 2. engine lib/ from staging (ONE real file per SONAME — symlink-free, no triplication) ==="
copy_soname(){ local f="$1" son
  son=$("$TARGET-readelf" -d "$f" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p' | head -1)
  [ -z "$son" ] && son=$(basename "$f")
  cp -f "$f" "$D/lib/$son"
}
# 2a. top-level libs: skip symlinks (real files only), skip legacy WPE 1.0 API + EGL stubs (device provides EGL)
for f in "$S"/lib/*.so*; do
  [ -L "$f" ] && continue
  case "$(basename "$f")" in libWPEWebKit-1.0.so*|libEGL.so*|libGLESv2.so*) continue;; esac
  copy_soname "$f"
done
# 2b. plugin/module subdirs are single real files — keep their names (-L in case any are symlinked)
for sub in gstreamer-1.0 gio wpe-webkit-2.0; do [ -d "$S/lib/$sub" ] && cp -rL "$S/lib/$sub" "$D/lib/"; done
find "$D/lib" \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true

echo "=== 3. glibc-2.23 + gcc runtime ==="
for l in ld-linux.so.3 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2 \
         libnss_dns.so.2 libnss_files.so.2 libnss_compat.so.2; do
  cp -fL "$GSR/lib/$l" "$D/lib/$l"
done
for l in libstdc++.so.6 libgcc_s.so.1 libatomic.so.1; do
  cp -fL "$(readlink -f "$($CC -print-file-name=$l)")" "$D/lib/$l"
done

echo "=== 4. Atlas components (backend, alsa plugin) ==="
cp -f "$WPE/backend-atlas/libWPEBackend-atlas.so" "$D/lib/libWPEBackend-atlas.so"
if [ -f "$WPE/libgstalsa.so" ]; then cp -f "$WPE/libgstalsa.so" "$D/lib/gstreamer-1.0/libgstalsa.so";
else echo "  WARN: libgstalsa.so missing (mic/speaker won't enumerate) — run audio/build-alsa-plugin.sh"; fi

echo "=== 5. libexec (WebProcess/NetworkProcess + gst scanner) ==="
cp -rL "$S/libexec/." "$D/libexec/"

echo "=== 6. share/ (pruned) ==="
for sd in glib-2.0 mime dbus-1 gstreamer-1.0 p11-kit icu themes locale/en; do
  [ -e "$S/share/$sd" ] && { mkdir -p "$D/share/$(dirname "$sd")"; cp -rL "$S/share/$sd" "$D/share/$sd"; } || true
done

echo "=== 7. engine data files (fonts.conf, gstomx.conf) ==="
cp -f "$WPE/ipk-build/pull/fonts.conf" "$D/fonts.conf"
cp -f "$WPE/gst-omx-config/gstomx.conf" "$D/gstomx.conf"

echo "=== 8. BrowserServer-atlas + atlas/ (wrapper, qcamd) ==="
cp -f "$OBJ/BrowserServer-atlas" "$D/BrowserServer-atlas"
cp -f "$ENV/ipk-build/pull/wrapper-BrowserServer" "$A/BrowserServer"   # upstart execs ./BrowserServer
cp -f "$CAM/qcamd" "$A/qcamd"                                          # runs under SYSTEM glibc — do NOT patchelf/strip
chmod +x "$A/BrowserServer" "$A/qcamd" "$D/BrowserServer-atlas"
# LunaService role file — activate installs it into rootfs ls2 roles. WITHOUT it startService() fails
# ('Invalid permissions for org.webosports.browserserver') and BS exits 255 after WebKit init.
mkdir -p "$APP/deviceroot/ls2-roles"; cp -f "$ROLESRC" "$APP/deviceroot/ls2-roles/"
# Rootfs-install artifacts the postinst lays down (needed for a clean ipk install; the restore path
# skips them because rootfs survives a /var wipe): NPAPI adapter + upstart job.
mkdir -p "$APP/deviceroot/BrowserPlugins" "$APP/deviceroot/event.d"
cp -f "$ENV/ipk-build/pull/BrowserAdapterAtlas.so" "$APP/deviceroot/BrowserPlugins/"
cp -f "$ENV/ipk-build/pull/upstart-atlas"          "$APP/deviceroot/event.d/atlas"

echo "=== 8b. WebRTC-completeness guard (regression trap) ==="
# The WebRTC stack is assembled by COPYING the whole staging gstreamer-1.0/ dir + all staging libs (steps
# 2a/2b) — so it is only complete if these were built into staging first (build-gst-webrtc.sh = transport,
# build-gst-webrtc-media.sh = codecs/RTP). A missing plugin ships a browser that shows only "Local Preview"
# on video calls. Fail LOUD here instead of silently shipping that. Split: transport (data channels) vs
# media (audio/video calls). Codec libs (libvpx/libopus) are picked up by the step-2a *.so loop.
gst="$D/lib/gstreamer-1.0"
miss=""
for p in libgstwebrtc.so libgstnice.so libgstdtls.so libgstsrtp.so libgstsctp.so libgstrtpmanager.so \
         libgstrtp.so libgstvpx.so libgstopus.so; do
  [ -f "$gst/$p" ] || miss="$miss $p"
done
for l in libnice.so.10 libsrtp2.so.1 libvpx.so.8 libopus.so.0; do
  ls "$D/lib/$l"* >/dev/null 2>&1 || miss="$miss $l"
done
if [ -n "$miss" ]; then
  echo "  !! WebRTC INCOMPLETE — missing from staging:$miss"
  echo "  !! run build-gst-webrtc.sh (transport) and/or build-gst-webrtc-media.sh (codecs) then re-run."
  exit 1
fi
echo "  WebRTC transport+media plugins all present."

if [ "$DOSTRIP" = 1 ]; then
  echo "=== 9. strip engine (STRIP=0 to keep symbols) ==="
  find "$D/lib" "$D/libexec" -type f -name '*.so*' -exec "$TARGET-strip" {} + 2>/dev/null || true
  "$TARGET-strip" "$D/libexec/wpe-webkit-2.0/WPEWebProcess" "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" \
                  "$D/BrowserServer-atlas" 2>/dev/null || true
fi

echo "=== 10. patchelf interp+rpath on atlas-loader execs (NOT qcamd) ==="
RP="$DEVPATH/lib:/usr/lib:/lib"
for b in "$D/libexec/wpe-webkit-2.0/WPEWebProcess" "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" "$D/BrowserServer-atlas"; do
  patchelf --set-interpreter "$DEVPATH/lib/ld-linux.so.3" --force-rpath --set-rpath "$RP" "$b"
done

echo "=== 11. prefix-patch baked host prefix -> /var/atlas252 (padded to same length) ==="
python3 - "$D" <<'PY'
import sys, os, glob
D = sys.argv[1]
host = b'/home/herrie/webos/wpe/staging-glibc-252'
dev  = b'/var/atlas252'
pad = b''
while len(dev + pad) < len(host): pad += b'/.'
devp = dev + pad[:len(host) - len(dev)]
assert len(devp) == len(host), (len(devp), len(host))
n = 0
for f in glob.glob(D + '/**', recursive=True):
    if os.path.isfile(f) and not os.path.islink(f):
        d = open(f, 'rb').read()
        if host in d:
            open(f, 'wb').write(d.replace(host, devp)); n += 1
print(f"  prefix-patched {n} files -> {devp.decode()}")
PY

echo "=== 12. tar the app dir ==="
cd "$OUT"
tar czf atlas-restore.tar.gz "$APPNAME"
echo "assembled: $(du -sh "$APP" | awk '{print $1}') app, tar=$(du -h atlas-restore.tar.gz | awk '{print $1}')"
echo "  libs=$(ls "$D/lib"/*.so* | wc -l)  gst=$(ls "$D/lib/gstreamer-1.0"/*.so | wc -l)  -> $OUT/atlas-restore.tar.gz"
