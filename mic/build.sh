#!/bin/bash
# Build the TouchPad microphone bridge for Atlas (mirror of ../camera/build.sh):
#   qmicd            -> PalmPDK/system-glibc daemon. Drives a webOS media-server
#                       captureV3 AUDIO recording over LunaService (the ONLY way to
#                       clock the DMIC/QDSP mic; hw:0 is exclusive), reads the WAV
#                       PCM from a FIFO, republishes S16LE chunks to shm + a socket.
#   libgstqmicsrc.so -> ATLAS gcc125 GStreamer source (mirror of libgstqcamsrc.so)
#                       reading that shm, so WPE WebKit's getUserMedia sees a
#                       "TouchPad Microphone" (audio/x-raw S16LE 16k mono).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

# Both binaries use the ATLAS gcc125 toolchain (glibc-2.52 staging + glib-2.70), the SAME
# pattern the BrowserServer uses to link LunaService (device liblunaservice was built for glib
# 2.16 but glib keeps ABI back-compat, so it runs fine against the atlas glib 2.70).  qmicd runs
# under the atlas LD_LIBRARY_PATH ($D/lib for glib + /usr/lib for the system liblunaservice).
WPE=/home/herrie/webos/wpe
DS=/home/herrie/webos/touchpad-kernel/doctor305
. $WPE/env-glibc-gcc125.sh 2>/dev/null
STAGING=${STAGING:-$WPE/staging-glibc-252}

# --- 1) qmicd: LunaService client + glib main loop ---
# lunaservice.h: use the clean luna-service2 header (no legacy <json.h>/<winsock2.h> drag-in);
# the device liblunaservice.so exports all the LS* symbols qmicd uses (verified via readelf).
SI=/home/herrie/tap2shared-re/src/webos_headers
DEVLIB=$WPE/browserserver-wpe/devlib         # liblunaservice.so (-> device /usr/lib)
GLIB_CF=$(pkg-config --cflags glib-2.0 gio-2.0)
GLIB_LIBS=$(pkg-config --libs   glib-2.0 gio-2.0)
RL=$DS/untouched-rootfs                       # device rootfs, for liblunaservice's transitive deps
# qmicd is an atlas glibc-2.52 binary — it MUST use the atlas ld-linux + lib rpath (the device's
# stock ld-linux/glibc-2.8 can't run it), exactly like the BrowserServer link.
DR=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot
echo "== qmicd (atlas gcc125 + lunaservice + glib) =="
# liblunaservice pulls in json-c (json_object_*) via libcjson/libmjson, shm_open via -lrt, and
# libgoodfork resolved by rpath-link into the device rootfs (same as the BS link).
$CC -O2 -Wall -o qmicd qmicd.c \
    -I"$SI" $GLIB_CF \
    -Wl,--dynamic-linker=$DR/wpe-252/lib/ld-linux.so.3 \
    -Wl,-rpath=$DR/wpe-252/lib:$DR/atlas:/usr/lib:/lib \
    -L"$DEVLIB" -llunaservice -lcjson -lmjson -lrt $GLIB_LIBS \
    -Wl,-rpath-link,"$STAGING/lib" -Wl,-rpath-link,"$RL/usr/lib" -Wl,-rpath-link,"$RL/lib"
echo "  ok: $(ls -la qmicd | awk '{print $5}') bytes"

# --- 2) libgstqmicsrc.so: ATLAS gcc125 against staging gst 1.20 (mirror of gstqcamsrc) ---
if [ -f gstqmicsrc.c ]; then
  GST_CFLAGS=$(pkg-config --cflags gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0)
  GST_LIBS=$(pkg-config --libs   gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0)
  echo "== libgstqmicsrc.so (atlas gcc125) =="
  $CC -O2 -Wall -fPIC -shared -o libgstqmicsrc.so gstqmicsrc.c $GST_CFLAGS $GST_LIBS \
      -Wl,-rpath-link,"$STAGING/lib"
  echo "  ok: $(ls -la libgstqmicsrc.so | awk '{print $5}') bytes"
fi

echo "DONE. Deploy: qmicd -> deviceroot/atlas/ (start from wrapper alongside qcamd, under SYSTEM env);"
echo "      role file org.webosports.qmicd.json -> /usr/share/ls2/roles/{pub,prv}/ ;"
echo "      libgstqmicsrc.so -> deviceroot/wpe-252/lib/gstreamer-1.0/."
