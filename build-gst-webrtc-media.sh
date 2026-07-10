#!/bin/bash
# WebRTC MEDIA stack (the piece build-gst-webrtc.sh did NOT cover). That script built the *transport*
# (webrtc/dtls/srtp/sctp/nice/rtpmanager) which is enough for RTCDataChannel — proven end-to-end. But an
# audio/video CALL (Teams, WhatsApp, meet) additionally needs, and was MISSING entirely:
#   * libgstrtp.so    RTP payloaders/depayloaders (rtpvp8pay, rtpopuspay, rtph264pay ...) — webrtcbin
#                     packetizes every media stream through these; no libgstrtp => "Local Preview" only
#                     (getUserMedia shows the local camera but the PeerConnection can't carry media).
#   * libgstvpx.so    VP8/VP9 encode+decode (WebRTC's default video codec)  -> needs libvpx
#   * libgstopus.so   Opus encode+decode (WebRTC's default audio codec)     -> needs libopus
# libgstrtp has NO external dep (RTP base lib libgstrtp-1.0 is already in gst-plugins-base staging).
# Builds into STAGING only; full-restore-atlas.sh then picks all of these up wholesale (it copies every
# staging/lib/*.so + the whole gstreamer-1.0/ dir), so the restore/ipk include them with no further edits.
# Deploy to a running device separately (see tail of this script / redeploy-webrtc.sh pattern).
set -u
WPE=/home/herrie/webos/wpe; L=$WPE/logs; mkdir -p "$L"
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"          # TARGET, CC, STAGING
S="$STAGING"
CROSS="$WPE/meson-cross-glibc-gcc125.txt"
export PKG_CONFIG_PATH="$S/lib/pkgconfig"
J=$(nproc)
stage(){ echo "===== $1 ====="; }

# ---------------------------------------------------------------------------------------------------
stage "1. libvpx 1.13.1 (VP8/VP9 codec lib)  [libvpx has its own configure, not meson]"
cd "$WPE/build"; rm -rf libvpx-1.13.1; tar xf "$WPE/src/libvpx-1.13.1.tar.gz" -C .
cd libvpx-1.13.1
# libvpx cross build: CROSS = toolchain prefix; target armv7-linux-gcc. NEON works fine under softfp
# (NEON is orthogonal to the float-call ABI). Shared lib, PIC, no tools/examples/docs/tests.
export CROSS="$TARGET-"
./configure --target=armv7-linux-gcc --prefix="$S" \
  --enable-pic --enable-shared --disable-static \
  --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
  --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-bins \
  > "$L/vpx.cfg" 2>&1 || { echo FAIL-VPX-CFG; tail -30 "$L/vpx.cfg"; exit 1; }
# glibc-2.23 keeps pthread/sem_* in libpthread (not folded into libc). libvpx's .so link rule puts
# $(extralibs) AFTER the objects (LDFLAGS goes before, gets dropped by --as-needed) — so inject
# -lpthread via the overridable extralibs make var, else: undefined reference to sem_*/pthread_*.
make -j"$J" extralibs='-lpthread' > "$L/vpx.make" 2>&1 && make install extralibs='-lpthread' >> "$L/vpx.make" 2>&1 \
  || { echo FAIL-VPX; tail -30 "$L/vpx.make"; exit 1; }
unset CROSS
echo "libvpx OK: $(ls "$S"/lib/libvpx.so* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"

# ---------------------------------------------------------------------------------------------------
stage "2. libopus 1.4 (Opus codec lib)  [autotools — opus-1.4's meson has an ARM bug:"
echo "   silk/meson.build refs undefined have_arm_intrinsics_or_asm; autotools cross-builds cleanly]"
cd "$WPE/build"; rm -rf opus-1.4; tar xf "$WPE/src/opus-1.4.tar.gz" -C .
cd opus-1.4
./configure --host="$TARGET" --prefix="$S" \
  --disable-static --enable-shared --disable-doc --disable-extra-programs --disable-intrinsics \
  > "$L/opus.cfg" 2>&1 || { echo FAIL-OPUS-CFG; tail -30 "$L/opus.cfg"; exit 1; }
make -j"$J" > "$L/opus.make" 2>&1 && make install >> "$L/opus.make" 2>&1 \
  || { echo FAIL-OPUS; tail -30 "$L/opus.make"; exit 1; }
echo "libopus OK: $(ls "$S"/lib/libopus.so* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"

# ---------------------------------------------------------------------------------------------------
stage "3. gst-plugins-good: rtp (payloaders) + vpx (VP8/VP9 element)"
cd "$WPE/build/gst-plugins-good-1.20.7"; rm -rf _bmedia
meson setup _bmedia --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Drtp=enabled -Dvpx=enabled -Drtpmanager=enabled \
  -Dexamples=disabled -Dtests=disabled -Ddoc=disabled -Dnls=disabled \
  > "$L/gstgood-media.cfg" 2>&1 || { echo FAIL-GOOD-CFG; tail -35 "$L/gstgood-media.cfg"; exit 1; }
ninja -C _bmedia gst/rtp/libgstrtp.so ext/vpx/libgstvpx.so > "$L/gstgood-media.make" 2>&1 \
  || { echo FAIL-GOOD; tail -35 "$L/gstgood-media.make"; exit 1; }
cp -f _bmedia/gst/rtp/libgstrtp.so "$S/lib/gstreamer-1.0/libgstrtp.so"
cp -f _bmedia/ext/vpx/libgstvpx.so "$S/lib/gstreamer-1.0/libgstvpx.so"
echo "libgstrtp + libgstvpx OK"

# ---------------------------------------------------------------------------------------------------
stage "4. gst-plugins-BASE: opus (opusenc/opusdec — the Opus codec element)"
# NOTE: at 1.20 the opus ENCODER/DECODER (opusenc/opusdec = libgstopus.so) live in gst-plugins-BASE,
# not bad. gst-plugins-bad's ext/opus only builds libgstopusparse.so (the parser). WebRTC needs enc/dec.
cd "$WPE/build/gst-plugins-base-1.20.7"; rm -rf _bopus
meson setup _bopus --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Dopus=enabled \
  -Dexamples=disabled -Dtests=disabled -Dintrospection=disabled -Ddoc=disabled \
  > "$L/gstbase-opus.cfg" 2>&1 || { echo FAIL-BASE-CFG; tail -35 "$L/gstbase-opus.cfg"; exit 1; }
ninja -C _bopus ext/opus/libgstopus.so > "$L/gstbase-opus.make" 2>&1 \
  || { echo FAIL-BASE; tail -35 "$L/gstbase-opus.make"; exit 1; }
cp -f _bopus/ext/opus/libgstopus.so "$S/lib/gstreamer-1.0/libgstopus.so"
echo "libgstopus OK"

# ---------------------------------------------------------------------------------------------------
stage "DONE — WebRTC media plugins now in staging"
echo "codec libs:   $(ls "$S"/lib/libvpx.so* "$S"/lib/libopus.so* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
echo "gst plugins:  $(ls "$S"/lib/gstreamer-1.0/{libgstrtp,libgstvpx,libgstopus}.so 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
echo "full-restore-atlas.sh / build-ipk.sh will bundle these automatically (they copy all staging libs +"
echo "the whole gstreamer-1.0 dir). To deploy to a LIVE device now: run deploy-gst-webrtc-media.sh."
