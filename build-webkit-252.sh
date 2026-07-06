#!/bin/bash
# WPE WebKit 2.52.4 cross-build — the TRUE ceiling (last pre-Skia stable; Cairo via USE_SKIA=OFF, libwpe
# FBO renderer via ENABLE_WPE_LEGACY_API=ON, USE_GBM=OFF honored natively at 2.52, soup3, C++23).
# Toolchain: gcc-12.5 (~/x-tools/...-gcc125). Staging: staging-glibc-252 (gcc-9.3 C deps + nghttp2 +
# libsoup3 built with gcc-12.5). The tree at build/wpewebkit-2.52.4 carries our single-process patch
# (WebKitWebContext.cpp) — so this script does NOT re-extract. $1=configure|build.
set -u
WPE=/home/herrie/webos/wpe; L=$WPE/logs
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
V=2.52.4
STAGE=${1:-configure}
B="$WPE/build/wpewebkit-$V"
[ -d "$B/Source" ] || { echo "ERROR: $B not extracted (single-process patch lives here)"; exit 1; }
if [ "$STAGE" = configure ]; then
  cd "$B"; rm -rf _b; mkdir _b; cd _b
  # NOTE: CMAKE_INSTALL_PREFIX="$S" bakes the host staging path into PKGLIBEXECDIR/PKGLIBDIR, so deploy-252.sh
  # must binary-patch it to the device path (a /var/atlas252 symlink -> cryptofs, since the real cryptofs path
  # is too long for the same-length patch). PROPER FIX for a future rebuild: set the prefix to the DEVICE path
  # and install into staging via DESTDIR, e.g.
  #     -DCMAKE_INSTALL_PREFIX=/var/atlas252   (short, symlinked to the cryptofs engine dir by postinst)
  #     ... && DESTDIR="$S/destroot" ninja install   (then point deploy/link -L at $S/destroot/var/atlas252/lib)
  # That bakes the correct paths at build time -> no prefix-patch, no /var bridge needed.
  nice -n 10 cmake .. -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${WPE_CMAKE_TC:-$WPE/cmake-toolchain-glibc-gcc125.cmake}" \
    -DCMAKE_INSTALL_PREFIX="$S" -DCMAKE_BUILD_TYPE=Release \
    -DPORT=WPE \
    -DENABLE_C_LOOP=ON -DENABLE_JIT=OFF -DENABLE_DFG_JIT=OFF -DENABLE_FTL_JIT=OFF \
    -DENABLE_SAMPLING_PROFILER=OFF -DENABLE_WEBASSEMBLY=OFF \
    -DUSE_GBM=OFF -DUSE_LIBDRM=OFF -DUSE_SKIA=OFF -DENABLE_WPE_LEGACY_API=ON -DENABLE_GPU_PROCESS=OFF \
    -DUNIFDEF_EXECUTABLE=$WPE/hostbin/unifdef \
    -DENABLE_VIDEO=OFF -DENABLE_WEB_AUDIO=OFF -DENABLE_MEDIA_SOURCE=OFF -DENABLE_MEDIA_STREAM=OFF \
    -DUSE_GSTREAMER=OFF \
    -DENABLE_WEB_RTC=OFF -DUSE_GSTREAMER_WEBRTC=OFF \
    -DENABLE_WEBGL=OFF -DENABLE_WEBGL2=OFF \
    -DENABLE_WEBDRIVER=OFF -DENABLE_INTROSPECTION=OFF -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_GAMEPAD=OFF -DENABLE_BUBBLEWRAP_SANDBOX=OFF -DENABLE_SPELLCHECK=OFF \
    -DUSE_ATK=OFF -DENABLE_ACCESSIBILITY=OFF \
    -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_ENCRYPTED_MEDIA=OFF -DENABLE_THUNDER=OFF \
    -DUSE_WOFF2=OFF -DUSE_LIBHYPHEN=OFF -DUSE_SYSTEMD=OFF -DUSE_LIBWPE=ON -DUSE_LIBBACKTRACE=OFF \
    -DUSE_OPENJPEG=OFF -DUSE_LCMS=OFF -DUSE_AVIF=OFF -DUSE_JPEGXL=OFF -DUSE_SYSTEM_SYSPROF_CAPTURE=NO \
    -DENABLE_MINIBROWSER=OFF -DENABLE_WEBXR=OFF -DENABLE_JOURNALD_LOG=OFF \
    > "$L/webkit-252.cfg" 2>&1
  rc=$?; echo "cmake configure rc=$rc"; tail -30 "$L/webkit-252.cfg"
else
  cd "$B/_b"
  export RUBYOPT="-r$WPE/ruby-compat.rb"
  nice -n 10 ninja -j 24 > "$L/webkit-252.make" 2>&1 && nice -n 10 ninja install >> "$L/webkit-252.make" 2>&1
  rc=$?; echo "ninja+install rc=$rc"; tail -20 "$L/webkit-252.make"
fi
exit $rc
