#!/bin/bash
# WPE WebKit 2.52.4 — HP Pre 3 FEATURE-STRIPPED variant (fresh build in a SEPARATE dir _b_pre3).
#
# Config = the working TouchPad engine's JIT / graphics-core / wasm flags kept IDENTICAL (so we inherit
# the ~3x DFG JIT + the softfp CCallHelpers patch that lives in Source/), with ONLY the heavy features
# dropped: video / media-source / media-stream / web-audio / webrtc / web-codecs / media-recorder /
# encrypted-media  ->  USE_GSTREAMER=OFF entirely; plus webgl / avif / jpegxl / speech-synth / gamepad.
# GPU_PROCESS already OFF. This is what the README calls the Phase-3 strip.
#
# Kept ON to match the proven build (do NOT change — softfp JIT is delicate): ENABLE_JIT, ENABLE_DFG_JIT,
# ENABLE_WEBASSEMBLY, ENABLE_C_LOOP=OFF, USE_SKIA=OFF, ENABLE_WPE_LEGACY_API=ON, USE_WOFF2=ON.
#
# Build dir _b_pre3 is separate from the working _b, and install goes to a DESTDIR destroot, so the
# TouchPad engine / staging-glibc-252 is never touched.
#
#   ./build-webkit-252-pre3.sh configure   # fresh cmake in _b_pre3 (~2-3 min; validates the config)
#   ./build-webkit-252-pre3.sh build        # ninja -j24 + DESTDIR install  (long; run in background)
set -u
WPE="${WPE:-$HOME/webos/wpe}"; L="$WPE/logs"; mkdir -p "$L"
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
V=2.52.4
B="$WPE/build/wpewebkit-$V"
BP="$B/_b_pre3"
DESTROOT="$WPE/pre3-destroot"
STAGE="${1:-configure}"
[ -d "$B/Source" ] || { echo "ERROR: $B not extracted (softfp/single-process patches live here)"; exit 1; }

if [ "$STAGE" = configure ]; then
  rm -rf "$BP"; mkdir -p "$BP"; cd "$BP"
  nice -n 10 cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${WPE_CMAKE_TC:-$WPE/cmake-toolchain-glibc-gcc125.cmake}" \
    -DCMAKE_INSTALL_PREFIX="$S" -DCMAKE_BUILD_TYPE=Release -DPORT=WPE \
    -DUNIFDEF_EXECUTABLE="$WPE/hostbin/unifdef" \
    `# --- JIT / core: IDENTICAL to the working engine ---` \
    -DENABLE_C_LOOP=OFF -DENABLE_JIT=ON -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF \
    -DENABLE_WEBASSEMBLY=ON -DENABLE_SAMPLING_PROFILER=OFF \
    -DUSE_GBM=OFF -DUSE_LIBDRM=OFF -DUSE_SKIA=OFF -DENABLE_WPE_LEGACY_API=ON -DENABLE_GPU_PROCESS=OFF \
    -DUSE_WOFF2=ON -DUSE_LIBWPE=ON \
    `# --- heavy features DROPPED for the 512MB Pre 3 ---` \
    -DENABLE_VIDEO=OFF -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_STREAM=OFF -DENABLE_WEB_AUDIO=OFF \
    -DENABLE_WEB_RTC=OFF -DUSE_GSTREAMER_WEBRTC=OFF -DUSE_GSTREAMER=OFF \
    -DENABLE_WEB_CODECS=OFF -DENABLE_MEDIA_RECORDER=OFF -DENABLE_MEDIA_CAPTURE=OFF -DENABLE_MEDIA_SESSION=OFF \
    -DENABLE_ENCRYPTED_MEDIA=OFF -DENABLE_THUNDER=OFF -DENABLE_SPEECH_SYNTHESIS=OFF \
    -DENABLE_WEBGL=OFF -DENABLE_WEBGL2=OFF -DENABLE_GAMEPAD=OFF \
    -DUSE_AVIF=OFF -DUSE_JPEGXL=OFF -DUSE_OPENJPEG=OFF -DUSE_LCMS=OFF \
    `# --- misc off (match build-webkit-252.sh) ---` \
    -DENABLE_WEBDRIVER=OFF -DENABLE_INTROSPECTION=OFF -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_BUBBLEWRAP_SANDBOX=OFF -DENABLE_SPELLCHECK=OFF -DUSE_ATK=OFF -DENABLE_ACCESSIBILITY=OFF \
    -DUSE_LIBHYPHEN=OFF -DUSE_SYSTEMD=OFF -DUSE_LIBBACKTRACE=OFF -DUSE_SYSTEM_SYSPROF_CAPTURE=NO \
    -DENABLE_MINIBROWSER=OFF -DENABLE_WEBXR=OFF -DENABLE_JOURNALD_LOG=OFF \
    > "$L/webkit-252-pre3.cfg" 2>&1
  rc=$?; echo "cmake configure rc=$rc"; tail -25 "$L/webkit-252-pre3.cfg"
  echo "--- key flags in _b_pre3 ---"
  grep -E "^(ENABLE_JIT|ENABLE_DFG_JIT|ENABLE_C_LOOP|ENABLE_WEBASSEMBLY|ENABLE_VIDEO|ENABLE_WEB_RTC|ENABLE_WEB_AUDIO|USE_GSTREAMER|ENABLE_WEBGL|USE_AVIF|USE_JPEGXL|ENABLE_MEDIA_STREAM):" CMakeCache.txt 2>/dev/null | sort
  exit $rc
else
  cd "$BP"
  export RUBYOPT="-r$WPE/ruby-compat.rb"
  nice -n 10 ninja -j 24 > "$L/webkit-252-pre3.make" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    rm -rf "$DESTROOT"; mkdir -p "$DESTROOT"
    nice -n 10 env DESTDIR="$DESTROOT" ninja install >> "$L/webkit-252-pre3.make" 2>&1; rc=$?
  fi
  echo "ninja+install rc=$rc"; tail -25 "$L/webkit-252-pre3.make"
  [ $rc -eq 0 ] && { echo "=== stripped libWPEWebKit ==="; ls -la "$BP"/lib/libWPEWebKit-2.0.so.1* 2>/dev/null; }
  exit $rc
fi
