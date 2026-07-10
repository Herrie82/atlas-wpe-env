#!/bin/bash
# Build the TouchPad camera bridge (Path B):
#   qcamd            -> PalmPDK/system-glibc daemon that drives the closed libqcameralib HAL and
#                       publishes NV12 frames to shm + a unix socket.
#   libgstqcamsrc.so -> ATLAS gcc125 GStreamer plugin (element + device provider) reading that shm,
#                       so WPE WebKit's getUserMedia sees a "TouchPad Front Camera" without dlopening
#                       the HAL (which hangs under the atlas glibc-2.25/glib-2.70 runtime).
# gstqcam_test / qcamd_testclient / qcam_probe are standalone validators.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# --- 1) qcamd + native validators: PalmPDK arm-none-linux-gnueabi-gcc-4.3.3 (device glibc-2.8) ---
PDK=/opt/PalmPDK/arm-gcc
PCC=$PDK/bin/arm-none-linux-gnueabi-gcc-4.3.3
PSYS=$PDK/sysroot
echo "== qcamd (PalmPDK) =="
$PCC --sysroot=$PSYS -O2 -Wall -o qcamd            qcamd.c            -ldl
$PCC --sysroot=$PSYS -O2 -Wall -o qcamd_testclient qcamd_testclient.c
$PCC --sysroot=$PSYS -O2 -Wall -o qcam_probe       qcam_probe.c       -ldl
echo "  ok: $(ls -la qcamd | awk '{print $5}') bytes"

# --- 2) libgstqcamsrc.so + gst test: ATLAS gcc125 against staging gst 1.20 ---
WPE=/home/herrie/webos/wpe
. $WPE/env-glibc-gcc125.sh 2>/dev/null
GST_CFLAGS=$(pkg-config --cflags gstreamer-1.0 gstreamer-base-1.0 gstreamer-video-1.0)
GST_LIBS=$(pkg-config --libs   gstreamer-1.0 gstreamer-base-1.0 gstreamer-video-1.0)
echo "== libgstqcamsrc.so (atlas gcc125) =="
$CC -O2 -Wall -fPIC -shared -o libgstqcamsrc.so gstqcamsrc.c $GST_CFLAGS $GST_LIBS
echo "  ok: $(ls -la libgstqcamsrc.so | awk '{print $5}') bytes"
echo "== gstqcam_test (atlas gcc125) =="
$CC -O2 -Wall -o gstqcam_test gstqcam_test.c $GST_CFLAGS $GST_LIBS -Wl,-rpath-link,$STAGING/lib
echo "  ok"
echo "DONE. Deploy: libgstqcamsrc.so -> deviceroot/wpe-252/lib/gstreamer-1.0/ ; qcamd -> /media/internal (or upstart)"
