#!/bin/bash
# gst-webrtc runtime stack for the device: libsrtp2 + libnice (openssl3) + gst-plugins-bad webrtc/nice/dtls/srtp
# plugins. Builds into staging only (NO device deploy here — deploy is a separate step verified against the
# existing plugin set). Needs OpenSSL 3 (done) for libnice DTLS + gst dtls plugin.
set -u
WPE=/home/herrie/webos/wpe; L=$WPE/logs
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
CROSS="$WPE/meson-cross-glibc-gcc125.txt"
export PKG_CONFIG_PATH="$S/lib/pkgconfig"
J=$(nproc)
stage(){ echo "===== $1 ====="; }

# 1. libsrtp2 (meson)
stage "libsrtp 2.6.0"
cd "$WPE/build"; rm -rf libsrtp-2.6.0; tar xf "$WPE/src/libsrtp-2.6.0.tar.gz" -C .
cd libsrtp-2.6.0
meson setup _b --cross-file "$CROSS" --prefix="$S" --buildtype=release --default-library=shared > "$L/srtp.cfg" 2>&1 \
  || { echo FAIL-SRTP-CFG; tail -25 "$L/srtp.cfg"; exit 1; }
ninja -C _b > "$L/srtp.make" 2>&1 && ninja -C _b install >> "$L/srtp.make" 2>&1 \
  || { echo FAIL-SRTP; tail -25 "$L/srtp.make"; exit 1; }
echo "libsrtp2 OK: $(ls "$S"/lib/libsrtp2.so* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"

# 2. libnice (meson, openssl crypto) — MUST build the GStreamer plugin (libgstnice.so), NOT just the lib.
#    webrtcbin uses the nicesrc/nicesink elements for ICE transport; without the plugin it fails with
#    "libnice elements are not available" and RTCDataChannel creation aborts (is_closed assertion) — the
#    data channel never opens. -Dgstreamer=enabled produces + installs $S/lib/gstreamer-1.0/libgstnice.so.
stage "libnice 0.1.21 (+GStreamer plugin)"
cd "$WPE/build"; rm -rf libnice-0.1.21; tar xf "$WPE/src/libnice-0.1.21.tar.gz" -C .
cd libnice-0.1.21
meson setup _b --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Dgstreamer=enabled -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Dgupnp=disabled \
  -Dcrypto-library=openssl > "$L/nice.cfg" 2>&1 || { echo FAIL-NICE-CFG; tail -25 "$L/nice.cfg"; exit 1; }
ninja -C _b > "$L/nice.make" 2>&1 && ninja -C _b install >> "$L/nice.make" 2>&1 \
  || { echo FAIL-NICE; tail -25 "$L/nice.make"; exit 1; }
echo "libnice OK: $(ls "$S"/lib/libnice.so* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
echo "libgstnice plugin: $(ls "$S"/lib/gstreamer-1.0/libgstnice.so 2>/dev/null || echo MISSING)"

# 3. gst-plugins-bad — webrtc/nice/dtls/srtp (+ sctp auto for data channels). auto elsewhere reproduces the
#    existing plugin set from available deps. Installs to staging; verify before deploy.
stage "gst-plugins-bad webrtc plugins"
cd "$WPE/build/gst-plugins-bad-1.20.7"; rm -rf _bwebrtc
meson setup _bwebrtc --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Dwebrtc=enabled -Ddtls=enabled -Dsrtp=enabled -Dsctp=auto \
  -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Ddoc=disabled \
  > "$L/gstbad.cfg" 2>&1 || { echo FAIL-GSTBAD-CFG; tail -35 "$L/gstbad.cfg"; exit 1; }
# build+install just the webrtc-relevant plugins to avoid rebuilding the whole set
ninja -C _bwebrtc > "$L/gstbad.make" 2>&1 && ninja -C _bwebrtc install >> "$L/gstbad.make" 2>&1 \
  || { echo FAIL-GSTBAD; tail -35 "$L/gstbad.make"; exit 1; }
echo "gst-plugins-bad done."

# 4. gst-plugins-GOOD rtpmanager (provides rtpbin — webrtcbin REQUIRES it, else 'rtpbin not found').
#    Not built in the original staging good-plugins set; build just this plugin.
stage "gst-plugins-good rtpmanager (rtpbin)"
cd "$WPE/build/gst-plugins-good-1.20.7"; rm -rf _brtp
meson setup _brtp --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Drtpmanager=enabled -Dexamples=disabled -Dtests=disabled -Ddoc=disabled -Dnls=disabled \
  > "$L/gstgood-rtp.cfg" 2>&1 || { echo FAIL-RTP-CFG; tail -25 "$L/gstgood-rtp.cfg"; exit 1; }
ninja -C _brtp gst/rtpmanager/libgstrtpmanager.so > "$L/gstgood-rtp.make" 2>&1 \
  || { echo FAIL-RTP; tail -25 "$L/gstgood-rtp.make"; exit 1; }
cp -f _brtp/gst/rtpmanager/libgstrtpmanager.so "$S/lib/gstreamer-1.0/libgstrtpmanager.so"
echo "rtpmanager OK"

echo "webrtc-related plugins now in staging:"
ls "$S"/lib/gstreamer-1.0/ | grep -iE "webrtc|nice|dtls|srtp|sctp|rtpmanager" | sed 's/^/  /'
echo "GST-WEBRTC-STACK OK. Deploy also needs libgstsctp-1.0.so.0 helper lib + clearing /tmp/atlas-gstreg.bin."
