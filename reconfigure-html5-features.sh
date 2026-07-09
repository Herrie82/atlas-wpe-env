#!/bin/bash
# html5test feature push (2026-07): INCREMENTAL reconfigure of the live _b build to flip on a batch of
# feature flags, WITHOUT wiping the working config. Do NOT use build-webkit-252.sh's `configure` — it is
# STALE (WEBGL/VIDEO/GSTREAMER/WASM/JIT=OFF) and would regress the engine. The real config lives in
# _b/CMakeCache.txt; `cmake .` re-runs with cached values and only the -D flags below change.
#
# Result: html5test.co 449 -> 479 (these flags) -> 481 (+ BrowserServer runtime settings: EME/idlecallback/
# prefetch, see atlas-wpe-backend BrowserPageWPE.cpp). After this: `cd _b && ninja -j24`, then redeploy-webkit.sh.
#
# NOTE the exclusions (learned the hard way, all verified at the cheap configure stage):
#   - ENABLE_POINTER_LOCK: breaks the WPE build — WebKitPointerLockPermissionRequest.h was never ported to
#     the WPE glib API in 2.52 (GTK-only). Would need a full GObject API type port. ~1pt. Left OFF.
#   - ENABLE_WEB_RTC / USE_GSTREAMER_WEBRTC: GStreamerChecks.cmake FATALs "OpenSSL 3 is needed" (SFrame);
#     staging has 1.1.1w. Needs an OpenSSL-3 cross-build sub-project. Left OFF. Worth up to 45pts.
#   - ENABLE_SPEECH_SYNTHESIS: FATALs without LibSpiel/Flite (neither in staging). ~2pts. Left OFF.
#   - VP9/AV1: SW decode too slow on APQ8060. Not pursued.
# WebCodecs gives Video/AudioDecoder but NOT ImageDecoder (unimplemented in 2.52) — so the html5test image
# format rows (WebP/JPEG/PNG/GIF) are NOT winnable here despite WebP <img> decode working fine.
set -u
WPE=/home/herrie/webos/wpe
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"
cd "$WPE/build/wpewebkit-2.52.4/_b" || { echo "no _b build dir"; exit 2; }
export RUBYOPT="-r$WPE/ruby-compat.rb"
nice -n 10 cmake . \
  -DENABLE_ENCRYPTED_MEDIA=ON \
  -DENABLE_MEDIA_STREAM=ON \
  -DENABLE_MEDIA_RECORDER=ON \
  -DENABLE_MEDIA_CAPTURE=ON \
  -DENABLE_WEB_CODECS=ON \
  -DENABLE_MEDIA_SESSION=ON \
  -DENABLE_DEVICE_ORIENTATION=ON \
  -DENABLE_ORIENTATION_EVENTS=ON \
  -DENABLE_POINTER_LOCK=OFF \
  -DENABLE_WEB_RTC=OFF -DUSE_GSTREAMER_WEBRTC=OFF
echo "reconfigure rc=$? — now: cd _b && ninja -j24 && ../../../deploy via redeploy-webkit.sh"
