#!/bin/bash
# FIX for the test.webrtc.org "DH lib" (SSL_R_DH_LIB) HTTPS failure.
#
# ROOT CAUSE: enabling WebRTC dragged OpenSSL 3 (libcrypto.so.3, via libWPEWebKit/libnice/libgstdtls)
# into the BrowserServer process, while HTTPS/TLS still ran on the process-private OpenSSL 1.1
# (/usr/lib/ssl11, via glib-networking's libgioopenssl.so). Two libcryptos in one global symbol
# namespace -> 1.1's TLS DH path gets its DH_*/BN_* symbols interposed by 3.0's incompatible impl ->
# DH computation fails -> SSL_R_DH_LIB. ECDHE sites dodge it; finite-field-DHE servers (test.webrtc.org)
# hit it and the page load dies at the handshake. You cannot share one process between OpenSSL 1.1 and 3.
#
# FIX: collapse the process onto ONE OpenSSL (3.0). Rebuild glib-networking's libgioopenssl against
# staging OpenSSL 3 so HTTPS/TLS uses libssl.so.3/libcrypto.so.3 too. Then libssl.so.1.1/libcrypto.so.1.1
# are no longer NEEDed by anything -> they stop loading -> no clash. WebRTC (already on OpenSSL 3, 45/45)
# is untouched; no WebKit rebuild. libssl.so.3 is already deployed on-device (redeploy-webrtc.sh step 1).
#
# OpenSSL 3's RNG/crypto are proven working on this 2.6.35 kernel already (WebRTC DTLS handshake succeeds).
set -u
WPE=/home/herrie/webos/wpe; L="$WPE/logs"; mkdir -p "$L"
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
CROSS="$WPE/meson-cross-glibc-gcc125.txt"
export PKG_CONFIG_PATH="$S/lib/pkgconfig"
SRC="$WPE/build/glib-networking-2.70.1"

cd "$SRC" || { echo "no glib-networking src"; exit 2; }
echo "=== sanity: staging openssl.pc must be OpenSSL 3 ==="
grep -i '^Version' "$S/lib/pkgconfig/openssl.pc" || true

rm -rf _b3
echo "=== meson configure (openssl backend only, against staging OpenSSL 3) ==="
meson setup _b3 --cross-file "$CROSS" --prefix="$S" --buildtype=release \
  -Dopenssl=enabled -Dgnutls=disabled -Dlibproxy=disabled -Dgnome_proxy=disabled \
  -Dinstalled_tests=false -Dstatic_modules=false \
  > "$L/gionet.cfg" 2>&1 || { echo FAIL-CFG; tail -40 "$L/gionet.cfg"; exit 1; }

echo "=== build ==="
ninja -C _b3 > "$L/gionet.make" 2>&1 || { echo FAIL-MAKE; tail -50 "$L/gionet.make"; exit 1; }

GIO=$(find _b3 -name 'libgioopenssl.so' | head -1)
[ -z "$GIO" ] && { echo "libgioopenssl.so not produced"; tail -20 "$L/gionet.make"; exit 1; }
echo "built: $GIO"
echo "=== NEEDED (must be libssl.so.3 + libcrypto.so.3, NOT .1.1) ==="
readelf -d "$GIO" 2>/dev/null | grep NEEDED | grep -iE 'ssl|crypto'
cp -f "$GIO" "$S/lib/gio/modules/libgioopenssl.so"
echo "installed to staging. OK — now deploy with deploy-gionetworking-openssl3.sh"
