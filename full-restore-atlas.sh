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
# 2c. AUDIO CODEC plugins guard — <audio>/WebRTC decode routes through these GStreamer element plugins.
# They come along via the 2b whole-dir copy ONLY IF present in staging; libgstogg.so (oggdemux) + libgstvorbis.so
# (vorbisdec) were built late (gst-plugins-base _bopus, -Dogg/-Dvorbis=enabled) and are easy to miss on a lean
# staging. Without oggdemux NO Ogg container decodes at all (not even Ogg-Opus). Underlying libogg.so.0/
# libvorbis.so.0/libvorbisenc.so.2/libopus.so.0 ride along via step 2a (real staging .so files). Fail LOUD.
for p in libgstogg.so libgstvorbis.so libgstopus.so; do
  if [ ! -f "$D/lib/gstreamer-1.0/$p" ]; then
    if [ -f "$S/lib/gstreamer-1.0/$p" ]; then cp -f "$S/lib/gstreamer-1.0/$p" "$D/lib/gstreamer-1.0/$p";
    else echo "  WARN: $p missing from staging (no Ogg/Vorbis/Opus decode) — build via gst-plugins-base _bopus -Dogg/-Dvorbis/-Dopus=enabled"; fi
  fi
done

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
# Camera GStreamer source (GstQcamSrc + GstQcamDevProvider) — surfaces the TouchPad front camera as a
# Video/Source device for getUserMedia. WITHOUT it navigator.mediaDevices sees videoin=0 (WebRTC shows
# "Local Preview only"). Not in staging (custom, built in camera-path-a); must be copied explicitly.
if [ -f "$CAM/libgstqcamsrc.so" ]; then cp -f "$CAM/libgstqcamsrc.so" "$D/lib/gstreamer-1.0/libgstqcamsrc.so";
else echo "  WARN: libgstqcamsrc.so missing (camera won't enumerate) — build it in camera-path-a"; fi
# Microphone GStreamer source (GstQmicSrc + GstQmicDevProvider) — surfaces the TouchPad DMIC as an
# Audio/Source ("TouchPad Microphone") for getUserMedia. The mic is a QDSP digital mic; qmicd drives a
# media-server captureV3 recording to clock it (hw:0 capture alone = silence). Built in mic/build.sh.
if [ -f "$ENV/mic/libgstqmicsrc.so" ]; then cp -f "$ENV/mic/libgstqmicsrc.so" "$D/lib/gstreamer-1.0/libgstqmicsrc.so";
else echo "  WARN: libgstqmicsrc.so missing (mic won't enumerate) — run mic/build.sh"; fi
# PulseAudio playback sink (atlaspasink, RANK_PRIMARY+20) — routes WebRTC/<audio> PLAYBACK through the ABI-stable
# pa_simple API to the system PulseAudio -> audiod -> speaker. WITHOUT it autoaudiosink falls back to alsasink ->
# ALSA 'default' -> the missing atlas pulse plugin -> "Could not open audio device" => received audio is MUTED
# (WebRTC far end inaudible; <audio>/speechSynthesis silent). Uses the SYSTEM libpulse stack on-device (same
# md5 as rootfs; reached via the wrapper's LD_LIBRARY_PATH=/usr/lib) — nothing else to ship. Built by build-gst-pasink.sh.
# DISABLED 2026-07-12: the prebuilt libgstatlaspasink.so links the SYSTEM libpulse (built for the old webOS
# glibc); loading it into the atlas glibc-2.52 WebProcess SIGSEGVs during the gst plugin scan -> the browser
# hangs mid-load. Do NOT deploy until libpulse (client) is rebuilt for the atlas glibc and atlaspasink is
# relinked against it (or replaced by a system-glibc speaker helper daemon, cf. qmicd/qcamd). Received audio
# stays muted until then. Re-enable this line once the atlas-built libpulse lands.
# if [ -f "$WPE/build/gst-pasink/libgstatlaspasink.so" ]; then cp -f "$WPE/build/gst-pasink/libgstatlaspasink.so" "$D/lib/gstreamer-1.0/libgstatlaspasink.so"; fi

echo "=== 5. libexec (WebProcess/NetworkProcess + gst scanner) ==="
cp -rL "$S/libexec/." "$D/libexec/"

echo "=== 6. share/ (pruned) ==="
for sd in glib-2.0 mime dbus-1 gstreamer-1.0 p11-kit icu themes locale/en alsa; do  # alsa: alsa.conf+cards/pcm — libasound needs it or mic/speaker enumerate 0 devices (WebRTC "Local Preview only")
  [ -e "$S/share/$sd" ] && { mkdir -p "$D/share/$(dirname "$sd")"; cp -rL "$S/share/$sd" "$D/share/$sd"; } || true
done
# mime DATABASE (GIO content-type): staging ships share/mime with NO mime.cache, so GIO can't map .html->text/html
# and WebKit DOWNLOADS local file:// pages instead of rendering them. Generate a real mime.cache from the host's
# freedesktop.org.xml (mime.cache is little-endian data = arch-independent for this ARM target). Regression from
# the reinstall that dropped it (cf. the alsa/qcam/qmic omissions).
if command -v update-mime-database >/dev/null 2>&1 && [ -f /usr/share/mime/packages/freedesktop.org.xml ]; then
  MB=$(mktemp -d); mkdir -p "$MB/packages"; cp /usr/share/mime/packages/freedesktop.org.xml "$MB/packages/"
  update-mime-database "$MB" >/dev/null 2>&1
  mkdir -p "$D/share/mime"; cp -rf "$MB/." "$D/share/mime/"; rm -rf "$MB"
  [ -f "$D/share/mime/mime.cache" ] && echo "  mime.cache OK" || echo "  WARN: mime.cache gen failed -> file:// html will DOWNLOAD"
else echo "  WARN: update-mime-database/freedesktop.org.xml missing -> file:// html will DOWNLOAD not render"; fi

echo "=== 7. engine data files (fonts.conf, gstomx.conf) ==="
cp -f "$WPE/ipk-build/pull/fonts.conf" "$D/fonts.conf"
cp -f "$WPE/gst-omx-config/gstomx.conf" "$D/gstomx.conf"

echo "=== 8. BrowserServer-atlas + atlas/ (wrapper, qcamd) ==="
cp -f "$OBJ/BrowserServer-atlas" "$D/BrowserServer-atlas"
cp -f "$ENV/ipk-build/pull/wrapper-BrowserServer" "$A/BrowserServer"   # upstart execs ./BrowserServer
cp -f "$CAM/qcamd" "$A/qcamd"                                          # runs under SYSTEM glibc — do NOT patchelf/strip
cp -f "$ENV/mic/qmicd" "$A/qmicd"                                      # ATLAS glibc-2.52 (ld-linux+rpath baked); the wrapper
                                                                      # starts it AFTER the atlas LD_LIBRARY_PATH export. MUST
                                                                      # run from $A/qmicd (== its ls2 role exeName) or ls-hubd denies it.
# Speaker daemon: received-audio PLAYBACK (WebRTC far end, <audio>, speechSynthesis). SYSTEM glibc; dlopen's the
# system libpulse. WITHOUT it (and its gst sink below) autoaudiosink falls back to alsasink -> broken pulse plugin
# -> received audio MUTED. Built by spk/build.sh. Started by the wrapper before the atlas LD_LIBRARY_PATH.
if [ -f "$ENV/spk/qspkd" ]; then cp -f "$ENV/spk/qspkd" "$A/qspkd"; else echo "  WARN: qspkd missing (received audio MUTED) — run spk/build.sh"; fi
if [ -f "$ENV/spk/libgstatlasqspksink.so" ]; then cp -f "$ENV/spk/libgstatlasqspksink.so" "$D/lib/gstreamer-1.0/libgstatlasqspksink.so"; else echo "  WARN: atlasqspksink missing"; fi
chmod +x "$A/BrowserServer" "$A/qcamd" "$A/qmicd" "$A/qspkd" "$D/BrowserServer-atlas" 2>/dev/null
# LunaService role files — activate installs them into rootfs ls2 roles. WITHOUT the role startService()/
# LSRegister fails ('Invalid permissions for org.webosports.<svc>'): BS exits 255; qmicd can't record.
mkdir -p "$APP/deviceroot/ls2-roles"; cp -f "$ROLESRC" "$APP/deviceroot/ls2-roles/"
cp -f "$ENV/roles/org.webosports.qmicd.json" "$APP/deviceroot/ls2-roles/"
[ -f "$ENV/mic/msm_media_case" ] && cp -f "$ENV/mic/msm_media_case" "$APP/deviceroot/msm_media_case"  # activate installs -> rootfs UCM
# NOTE (rootfs, not app): the mic also needs /usr/share/alsa/ucm/msm-audio/msm_media_case (absent on
# webOS 3.0.5, present in doctor306-opal) — it defines the UCM Force-route/DMIC capture route audiod
# applies. Deploy it once to the rootfs (mount -o remount,rw /; cp; reboot) — see full-restore-activate.sh.
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

echo "=== 8c. WebGL/ANGLE-fix guard (regression trap) ==="
# libWPEWebKit is copied from staging (step 2a). If staging holds a build made BEFORE the Adreno-220
# WebGL fix (ANGLE FunctionsEGLDL libGLESv2.so dlopen fallback, commit 09bee16 / patch
# wpe-2.52.4-atlas-webgl-angle-fixes.patch), the WebProcess SIGSEGVs on any WebGL page (glGetString via
# NULL) — html5test.co and every WebGL site crash. This exact regression shipped once when a full-reset
# restore pulled a stale staging binary. The fix compiles a `dlopen("libGLESv2.so")` — its arg string is
# a reliable presence marker. Fail LOUD if the assembled engine lacks it.
if strings -a "$D/lib/libWPEWebKit-2.0.so.1" 2>/dev/null | grep -q '^libGLESv2\.so$'; then
  echo "  WebGL/ANGLE core-GL fallback present (libGLESv2.so dlopen)."
else
  echo "  !! libWPEWebKit LACKS the Adreno WebGL fix — WebGL pages will SIGSEGV the WebProcess."
  echo "  !! staging is stale. Refresh: cp <wpewebkit>/_b/lib/libWPEWebKit-2.0.so.1.9.8 $S/lib/"
  echo "  !! (source patch = wpe-2.52.4-atlas-webgl-angle-fixes.patch, must be built into the lib)."
  exit 1
fi

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
