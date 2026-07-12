#!/bin/bash
# Build libgstatlaspasink.so — a minimal GStreamer 1.x audio sink (element "atlaspasink") that routes
# PLAYBACK through the system PulseAudio via the ABI-stable pa_simple API -> audiod -> speaker. Registered
# at GST_RANK_PRIMARY+20 so WebKit's autoaudiosink prefers it over alsasink (whose ALSA 'default' -> pulse
# plugin is missing in the atlas prefix -> "Could not open audio device" -> received WebRTC audio MUTED).
# Uses the SYSTEM libpulse/libpulse-simple on-device (byte-identical to the rootfs copies kept here for the
# link); reached at runtime via the wrapper's LD_LIBRARY_PATH=/usr/lib. Deploy: full-restore-atlas.sh copies it.
set -e
WPE=/home/herrie/webos/wpe; . "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"
cd "$WPE/build/gst-pasink"
PKGS="gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0 glib-2.0 gobject-2.0"
# pulse client headers (pa_simple) — from the pulseaudio-0.9.22 source tree kept in build/ (matches the
# ABI-stable libpulse-simple we link + the system libpulse on-device).
PULSE_INC="$WPE/build/pulseaudio-0.9.22/src"
CF="$(pkg-config --cflags $PKGS) -I$PULSE_INC -DPACKAGE='\"atlaspasink\"' -DVERSION='\"1.0\"'"
LF=$(pkg-config --libs $PKGS)
$CC $CFLAGS -std=gnu11 -fPIC -Wall $CF \
    -shared -Wl,-soname,libgstatlaspasink.so \
    -o libgstatlaspasink.so gstpasink.c \
    $LF -lpulse-simple -lpulse -L. -Wl,-rpath-link,"$STAGING/lib" -Wl,-rpath-link,.
echo "=== built ==="
ls -l libgstatlaspasink.so | awk '{print "  ",$5,$NF}'
$TARGET-readelf -hA libgstatlaspasink.so | grep -iE 'Machine|soft-float' | sed 's/^/  /'
echo "  NEEDED: $($TARGET-readelf -d libgstatlaspasink.so | grep -oE '\[lib[^]]+\]' | tr '\n' ' ')"
