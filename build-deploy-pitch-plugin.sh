#!/bin/bash
# Add the GStreamer 'pitch' element (fixes "The pitch GStreamer plugin is unavailable. The pitch property
# of Speech Synthesis is ignored."). 'pitch' lives in gst-plugins-bad's `soundtouch` plugin, which needs the
# SoundTouch C++ library. Same recipe as the WebRTC gst plugins. Builds into staging + deploys to device.
#   1. SoundTouch 2.3.3 (cmake cross-build) -> libSoundTouch.so.2 + soundtouch.pc
#   2. gst-plugins-bad -Dsoundtouch=enabled -> libgstsoundtouch.so (provides `pitch`, `bpmdetect`)
#   3. deploy both, clear /tmp/atlas-gstreg.bin so the plugin is rescanned.
set -u
WPE=/home/herrie/webos/wpe; L=$WPE/logs; mkdir -p "$L"
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
CROSS="$WPE/meson-cross-glibc-gcc125.txt"
export PKG_CONFIG_PATH="$S/lib/pkgconfig"
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252

echo "=== 1. SoundTouch 2.3.3 ==="
[ -f "$WPE/src/soundtouch-2.3.3.tar.gz" ] || curl -sL --max-time 60 -o "$WPE/src/soundtouch-2.3.3.tar.gz" \
  "https://codeberg.org/soundtouch/soundtouch/archive/2.3.3.tar.gz"
cd "$WPE/build"; rm -rf soundtouch; tar xzf "$WPE/src/soundtouch-2.3.3.tar.gz" -C .
cd soundtouch
cmake -S . -B _b -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_INSTALL_PREFIX="$S" \
  -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DBUILD_SHARED_LIBS=ON -DSOUNDSTRETCH=OFF -DCMAKE_FIND_ROOT_PATH="$S" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY > "$L/soundtouch.cfg" 2>&1 || { echo FAIL-ST-CFG; tail -20 "$L/soundtouch.cfg"; exit 1; }
make -C _b -j8 > "$L/soundtouch.make" 2>&1 && make -C _b install >> "$L/soundtouch.make" 2>&1 \
  || { echo FAIL-ST; tail -20 "$L/soundtouch.make"; exit 1; }
echo "  libSoundTouch: $(ls $S/lib/libSoundTouch.so.* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"

echo "=== 2. gst-plugins-bad soundtouch plugin ==="
cd "$WPE/build/gst-plugins-bad-1.20.7"; rm -rf _bst
meson setup _bst --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Dsoundtouch=enabled -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Ddoc=disabled \
  > "$L/gstst.cfg" 2>&1 || { echo FAIL-GST-CFG; tail -25 "$L/gstst.cfg"; exit 1; }
ninja -C _bst ext/soundtouch/libgstsoundtouch.so > "$L/gstst.make" 2>&1 || { echo FAIL-GST; tail -25 "$L/gstst.make"; exit 1; }
cp -f _bst/ext/soundtouch/libgstsoundtouch.so "$S/lib/gstreamer-1.0/libgstsoundtouch.so"
echo "  libgstsoundtouch.so built"

echo "=== 3. deploy (real SoundTouch file under soname + plugin) ==="
novacom put file://"$DEV/lib/libSoundTouch.so.2" < "$(readlink -f $S/lib/libSoundTouch.so.2)" && echo "  libSoundTouch OK"
novacom put file://"$DEV/lib/gstreamer-1.0/libgstsoundtouch.so" < "$S/lib/gstreamer-1.0/libgstsoundtouch.so" && echo "  plugin OK"
echo "=== restart atlas (clears gst registry so pitch is rescanned) ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null; for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 2; rm -f /tmp/atlas-gstreg.bin /tmp/bs-atlas.log; start atlas 2>/dev/null; sleep 5; echo restarted
SH
echo "Done. Verify: no 'pitch GStreamer plugin is unavailable' in /tmp/bs-atlas.log; SpeechSynthesisUtterance.pitch honored."
