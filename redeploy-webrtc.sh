#!/bin/bash
# FULL deploy of the html5test overnight batch (input types + WebRTC + OpenSSL 3) to the device.
# Prereqs (all DONE in staging as of 2026-07-09 night): libWPEWebKit rebuilt w/ ENABLE_WEB_RTC + input-type
# prefs; OpenSSL 3.0.16; gst webrtc plugins (webrtc/dtls/srtp/sctp) + libnice + libsrtp2 in staging.
# RUN ONLY when the device is rebooted and novacom is healthy (`novacom -l` returns).
#
# Deploys, in order:
#   1. OpenSSL 3 runtime  (libcrypto.so.3, libssl.so.3)   -> engine lib dir  [CRITICAL: libWPEWebKit NEEDs it]
#   2. WebRTC support libs (libnice.so.10, libsrtp2.so.1, libgstwebrtc-1.0.so.0) -> engine lib dir
#   3. gst webrtc plugins  (libgstwebrtc/dtls/srtp/sctp/rtpmanagerbad.so) -> device GST plugin dir
#   4. libWPEWebKit-2.0.so.1 (prefix-patched) -> engine lib dir
#   5. BrowserServer-atlas (input-type toggles + EME) -> engine dir
#   then restart atlas.
# The new .so's have NO baked rpath -> they resolve via the wrapper's LD_LIBRARY_PATH (=engine lib dir).
#
# ONE DEVICE-SPECIFIC UNKNOWN to confirm first: the GST plugin dir the engine scans. Check on device:
#   novacom run file://bin/sh <<'X'
#   cat /proc/$(pgrep -f BrowserServer-atlas)/environ | tr '\0' '\n' | grep -i GST_PLUGIN
#   X
# Default guess below is $DEV/lib/gstreamer-1.0 . Override: GST_PLUGIN_DIR=... ./redeploy-webrtc.sh
set -u
WPE=/home/herrie/webos/wpe; S=$WPE/staging-glibc-252
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
GST_PLUGIN_DIR="${GST_PLUGIN_DIR:-$DEV/lib/gstreamer-1.0}"
B="$WPE/build/wpewebkit-2.52.4/_b"
TGT=$(ls "$WPE"/x-tools/*/bin/*-strip 2>/dev/null | head -1)

put(){ # $1=host file  $2=device abs path
  echo "  put $(basename "$2") ($(stat -c%s "$1") b)"
  novacom put file://"$2" < "$1" || { echo "  !! put failed: $2"; return 1; }
}

echo "=== stop atlas + kill engine ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo "stopped"
SH

echo "=== 1. OpenSSL 3 runtime -> $DEV/lib (deploy under SONAME) ==="
put "$S/lib/libcrypto.so.3" "$DEV/lib/libcrypto.so.3"
put "$S/lib/libssl.so.3"    "$DEV/lib/libssl.so.3"

echo "=== 2. WebRTC support libs -> $DEV/lib ==="
# libgstsctp-1.0.so.0 is the SCTP helper lib (webrtcbin NEEDs it); easy to miss vs the sctp plugin.
for son in libnice.so.10 libsrtp2.so.1 libgstwebrtc-1.0.so.0 libgstsctp-1.0.so.0; do
  real=$(readlink -f "$S/lib/$son"); put "$real" "$DEV/lib/$son"
done

echo "=== 3. gst webrtc plugins -> $GST_PLUGIN_DIR ==="
# webrtcbin also needs rtpbin (rtpmanager, from gst-plugins-GOOD) AND libgstnice.so (the libnice GStreamer
# plugin — provides nicesrc/nicesink ICE transport; without it webrtcbin aborts data-channel creation with
# "libnice elements are not available"). Both built separately, see build-gst-webrtc.sh.
for p in libgstwebrtc.so libgstdtls.so libgstsrtp.so libgstsctp.so libgstrtpmanagerbad.so libgstrtpmanager.so libgstnice.so; do
  put "$S/lib/gstreamer-1.0/$p" "$GST_PLUGIN_DIR/$p"
done

echo "=== 4. libWPEWebKit (prefix-patch host staging -> /var/atlas252, then put) ==="
TMP=$(mktemp /tmp/libwpe.XXXX.so); cp -f "$B/lib/libWPEWebKit-2.0.so.1.9.8" "$TMP"
python3 - "$TMP" <<'PY'
import sys
host=b'/home/herrie/webos/wpe/staging-glibc-252'; dev=b'/var/atlas252'
pad=b''
while len(dev+pad)<len(host): pad+=b'/.'
pad=pad[:len(host)-len(dev)]; devp=dev+pad; assert len(devp)==len(host)
f=sys.argv[1]; d=open(f,'rb').read(); open(f,'wb').write(d.replace(host,devp))
print(f"  prefix-patched {d.count(host)} occurrences")
PY
put "$TMP" "$DEV/lib/libWPEWebKit-2.0.so.1"; rm -f "$TMP"

echo "=== 5. BrowserServer-atlas ==="
put "$WPE/browserserver-wpe/obj/BrowserServer-atlas" "$DEV/BrowserServer-atlas"

echo "=== restart atlas, wait for socket ==="
# MUST clear the GStreamer registry cache so the new plugins (rtpmanager etc.) get rescanned, else
# webrtcbin fails with 'rtpbin not found'. GST_REGISTRY=/tmp/atlas-gstreg.bin.
cat <<'SH' | novacom run file://bin/sh
rm -f /tmp/bs-atlas.log /tmp/yapserver.atlas /tmp/atlas-gstreg.bin
start atlas 2>/dev/null; sleep 5
i=0; while [ $i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=$((i+1)); done
echo "socket up after $((i+5))s; BS=$(ps -ef|grep -c '[B]rowserServer-atlas')"
# quick sanity: did libWPEWebKit load (needs libcrypto.so.3)? BS alive => yes
SH
echo "=== done. Verify with html5test.co scrape (see atlas-html5test-plan memory). ==="
echo "Expect: input types (date/month/week/time/datetime-local/color) -> Yes; WebRTC 1.0 / Data channel -> Yes."
