#!/bin/bash
# Build the Atlas speaker path (received-audio playback):
#   qspkd                     — SYSTEM-glibc daemon: reads PCM from /tmp/qspkd.sock, plays via system pa_simple.
#   libgstatlasqspksink.so    — ATLAS-glibc gst sink (element "atlasqspksink", RANK_PRIMARY+20): pipes PCM to
#                               the socket. NO libpulse dep (that would SIGSEGV the atlas WebProcess). See qspkd.c.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WPE=/home/herrie/webos/wpe

echo "=== 1. qspkd  (SYSTEM glibc: PalmPDK arm-2009q1 + system libpulse) ==="
PDK=/home/herrie/webos/touchpad-kernel/doctor305/isis-project/toolchain/arm-2009q1/bin/arm-none-linux-gnueabi
PULSE_INC="$WPE/build/pulseaudio-0.9.22/src"     # pa_simple.h — types/enums only (functions are dlopen'd)
# qspkd DLOPENs libpulse-simple at runtime, so it links only libc + libdl here (no libpulse chain, no --sysroot).
"$PDK-gcc" -O2 -Wall -o "$HERE/qspkd" "$HERE/qspkd.c" -I"$PULSE_INC" -ldl
echo "  qspkd: $(ls -l "$HERE/qspkd" | awk '{print $5}') bytes"
"$PDK-readelf" -h "$HERE/qspkd" | grep -iE 'Machine' | sed 's/^/  /'
echo "  NEEDED: $("$PDK-readelf" -d "$HERE/qspkd" | grep -oE '\[lib[^]]+\]' | tr '\n' ' ')"

echo "=== 2. libgstatlasqspksink.so  (ATLAS glibc-2.52, NO pulse dep) ==="
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"
PKGS="gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0 glib-2.0 gobject-2.0"
$CC $CFLAGS -std=gnu11 -fPIC -Wall $(pkg-config --cflags $PKGS) \
    -DPACKAGE='"atlasqspksink"' -DVERSION='"1.0"' \
    -shared -Wl,-soname,libgstatlasqspksink.so \
    -o "$HERE/libgstatlasqspksink.so" "$HERE/gstqspksink.c" \
    $(pkg-config --libs $PKGS) -Wl,-rpath-link,"$STAGING/lib"
echo "  sink: $(ls -l "$HERE/libgstatlasqspksink.so" | awk '{print $5}') bytes"
$TARGET-readelf -hA "$HERE/libgstatlasqspksink.so" | grep -iE 'Machine|soft-float' | sed 's/^/  /'
NEED="$($TARGET-readelf -d "$HERE/libgstatlasqspksink.so" | grep -oE '\[lib[^]]+\]' | tr '\n' ' ')"
echo "  NEEDED: $NEED"
case "$NEED" in *pulse*) echo "  !! ERROR: sink links libpulse — it must NOT (would SIGSEGV in atlas)"; exit 1;; esac
echo "  OK: no libpulse dep in the atlas sink."
