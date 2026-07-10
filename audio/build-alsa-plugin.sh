#!/bin/bash
# Build the ALSA GStreamer plugin (libgstalsa.so) for Atlas so getUserMedia/WebRTC/webcam.org see the
# TouchPad microphone (ALSA hw:0,1 "Media Capture wm8994-aif2-1") and speaker. The stock atlas gst build
# shipped NO alsa plugin (no alsa-lib in the cross sysroot) -> navigator.mediaDevices reported audioinput:0.
#
# alsadeviceprovider (klass Sink/Source/Audio) enumerates BOTH Audio/Source (mic) and Audio/Sink (speaker),
# so this one plugin covers mic + speaker detection. WebKit's capture manager finds it with no rebuild.
#
# Two steps:
#   1. Cross-build alsa-lib 1.0.24.1 (EXACT match to the device's /usr/lib/libasound.so.2.0.0, so the plugin
#      binds only symbols the device libasound exports) -> staging headers + libasound + alsa.pc.
#   2. Compile gst-plugins-base ext/alsa standalone (atlas gcc125), MINUS gstalsamidisrc.c and its
#      registration -- the device libasound was built --disable-seq, so snd_seq_* is undefined and the
#      whole plugin fails to load ("symbol snd_seq_event_input ... not defined") if midi is included.
#
# Runtime: the plugin links libasound.so.2 which resolves from the device's /usr/lib (glibc is backward
# compatible, so the glibc-2.8 device libasound loads fine in the atlas glibc-2.25 WebProcess) -- do NOT
# deploy our staging libasound (its baked config path would send libasound looking for a nonexistent
# /var/atlas252/share/alsa and break "hw:" resolution). Deploy ONLY libgstalsa.so.
#
# Also required on device: libgstvideorate.so (see the camera fix) -- unrelated to audio but both are
# deployed to $DR/wpe-252/lib/gstreamer-1.0/. Clear /tmp/atlas-gstreg.bin after deploying so they scan.
set -e
WPE=/home/herrie/webos/wpe
. "$WPE/env-glibc-gcc125.sh"
GB=$WPE/build/gst-plugins-base-1.20.7

# --- 1) alsa-lib 1.0.24.1 (device-matched) ---
cd "$WPE/build"
[ -f alsa-lib-1.0.24.1.tar.bz2 ] || curl -sSL -o alsa-lib-1.0.24.1.tar.bz2 \
  https://www.alsa-project.org/files/pub/lib/alsa-lib-1.0.24.1.tar.bz2
rm -rf alsa-lib-1.0.24.1; tar xf alsa-lib-1.0.24.1.tar.bz2; cd alsa-lib-1.0.24.1
./configure --host=arm-unknown-linux-gnueabi --prefix="$STAGING" --disable-python \
  --disable-static --enable-shared CC="$CC"
make -j4 && make install

# --- 2) libgstalsa.so (no MIDI) ---
WORK=$(mktemp -d); cp "$GB"/ext/alsa/*.c "$GB"/ext/alsa/*.h "$WORK"/
# drop the alsamidisrc registration (source dropped from the compile list below)
sed -i 's#ret |= GST_ELEMENT_REGISTER (alsamidisrc, plugin);#/* alsamidisrc removed: device libasound built --disable-seq (no snd_seq_*) */#' \
  "$WORK/gstalsaplugin.c"
# Atlas device-selection fix: the stock provider exposes ALL 4 wm8994 PCMs per direction, so WebKit
# picked the busy MVS telephony node (hw:0,3) as the default mic. Overlay the patched provider that
# exposes ONLY the real Media Capture (hw:0,1 mic) + Media Playback (hw:0,0 speaker), marked default.
cp -f "$(dirname "$0")/gstalsadeviceprovider.c.atlas" "$WORK/gstalsadeviceprovider.c"
cd "$WORK"
CF=$(pkg-config --cflags gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0 alsa)
LF=$(pkg-config --libs   gstreamer-1.0 gstreamer-base-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0 alsa)
"$CC" -O2 -fPIC -shared -DHAVE_CONFIG_H -o "$WPE/libgstalsa.so" \
  gstalsa.c gstalsadeviceprovider.c gstalsaelement.c gstalsaplugin.c gstalsasink.c gstalsasrc.c \
  -I"$GB/_b" -I"$GB" -I"$GB/gst-libs" $CF $LF
"$TARGET-strip" "$WPE/libgstalsa.so"
echo "built $WPE/libgstalsa.so"
echo "Deploy: -> \$DR/wpe-252/lib/gstreamer-1.0/libgstalsa.so ; also ensure libgstvideorate.so is deployed;"
echo "        then rm /tmp/atlas-gstreg.bin and restart atlas."
