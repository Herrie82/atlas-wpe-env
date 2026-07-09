#!/bin/bash
# OpenSSL 3.x cross-build for WebRTC (GStreamerChecks.cmake FATALs without OpenSSL>=3 for SFrame).
# Adapted from build-openssl.sh (1.1.1w). OpenSSL 3 (.so.3) coexists with 1.1 (.so.1.1) by soname; libWPEWebKit
# doesn't link OpenSSL today (soup=GnuTLS) so there's no conflict. Installs into staging; backs up the 1.1
# headers/.pc/.a first (the .so.1.1 files are name-distinct and survive).
set -u
WPE=/home/herrie/webos/wpe; L=$WPE/logs
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
unset CC CXX AR RANLIB STRIP LD CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
V=3.0.16
# 1. backup 1.1 artifacts that install_sw would overwrite
BK="$S/.openssl11-backup"; mkdir -p "$BK/include" "$BK/lib/pkgconfig"
cp -a "$S"/include/openssl "$BK/include/" 2>/dev/null || true
cp -a "$S"/lib/libssl.a "$S"/lib/libcrypto.a "$BK/lib/" 2>/dev/null || true
cp -a "$S"/lib/pkgconfig/openssl.pc "$S"/lib/pkgconfig/libssl.pc "$S"/lib/pkgconfig/libcrypto.pc "$BK/lib/pkgconfig/" 2>/dev/null || true
echo "backed up 1.1 artifacts to $BK"
# 2. fetch
cd "$WPE/src"
[ -f openssl-$V.tar.gz ] || curl -fsSL -o openssl-$V.tar.gz \
  https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz || { echo FAIL-DL; exit 1; }
rm -rf "$WPE/build/openssl-$V"; tar xf openssl-$V.tar.gz -C "$WPE/build" || { echo FAIL-EXTRACT; exit 1; }
cd "$WPE/build/openssl-$V"
# 3. configure — same target/flags as 1.1; no-docs/no-tests to speed up
./Configure linux-armv4 --prefix="$S" --openssldir="$S/ssl" shared no-tests \
  --cross-compile-prefix="$TARGET-" \
  -march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp \
  > "$L/openssl3.cfg" 2>&1 || { echo FAIL-CFG; tail -20 "$L/openssl3.cfg"; exit 1; }
echo "configured; building..."
make -j"$(nproc)" > "$L/openssl3.make" 2>&1 || { echo FAIL-MAKE; tail -25 "$L/openssl3.make"; exit 1; }
make install_sw > "$L/openssl3.inst" 2>&1 || { echo FAIL-INST; tail -20 "$L/openssl3.inst"; exit 1; }
echo "=== OpenSSL 3 install: pc version + sonames ==="
grep -i "^Version" "$S/lib/pkgconfig/openssl.pc"
ls -l "$S/lib/libssl.so"* "$S/lib/libcrypto.so"* 2>/dev/null | sed 's|.*/lib/||'
echo "OPENSSL3 OK"
