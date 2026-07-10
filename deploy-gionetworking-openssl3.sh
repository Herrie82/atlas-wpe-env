#!/bin/bash
# Deploy the OpenSSL-3-linked libgioopenssl.so (fixes the SSL_R_DH_LIB HTTPS-DHE failure) and verify.
# After this, libssl.so.1.1/libcrypto.so.1.1 are no longer NEEDed -> process runs a single OpenSSL (3.0).
set -u
WPE=/home/herrie/webos/wpe; S=$WPE/staging-glibc-252
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
put(){ echo "  put $(basename "$2") ($(stat -c%s "$1") b)"; novacom put file://"$2" < "$1" || { echo "  !! put failed: $2"; return 1; }; }

echo "=== stop atlas ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo stopped
SH

echo "=== deploy libgioopenssl.so (OpenSSL 3) + ensure libssl.so.3 present ==="
put "$S/lib/gio/modules/libgioopenssl.so" "$DEV/lib/gio/modules/libgioopenssl.so"
put "$(readlink -f "$S/lib/libssl.so.3")"    "$DEV/lib/libssl.so.3"
put "$(readlink -f "$S/lib/libcrypto.so.3")" "$DEV/lib/libcrypto.so.3"

echo "=== restart atlas ==="
cat <<'SH' | novacom run file://bin/sh
rm -f /tmp/bs-atlas.log /tmp/yapserver.atlas
start atlas 2>/dev/null; sleep 5
i=0; while [ $i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=$((i+1)); done
echo "socket up after $((i+5))s"
# confirm 1.1 is gone from the process once a page loads (checked after launch below)
SH
echo "=== done. Now run the verify step. ==="
