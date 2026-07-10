#!/bin/bash
# Deploy the WebRTC MEDIA plugins (built by build-gst-webrtc-media.sh) to a LIVE device, then restart
# atlas clearing the gst registry so the new elements get scanned. These .so's have no baked rpath — they
# resolve via the wrapper's LD_LIBRARY_PATH (=engine lib dir). Run only when novacom is healthy.
#   codec libs   -> $DEV/lib               (libvpx.so.*, libopus.so.*)
#   gst plugins  -> $DEV/lib/gstreamer-1.0 (libgstrtp.so, libgstvpx.so, libgstopus.so)
set -u
WPE=/home/herrie/webos/wpe; S=$WPE/staging-glibc-252
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
GST=$DEV/lib/gstreamer-1.0

put(){ echo "  put $(basename "$2") ($(stat -c%s "$1") b)"; novacom put file://"$2" < "$1" || { echo "  !! put failed: $2"; return 1; }; }

echo "=== stop atlas + kill engine ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo stopped
SH

echo "=== 1. codec libs -> $DEV/lib (under SONAME) ==="
for son in $(cd "$S/lib" && ls libvpx.so.* libopus.so.* 2>/dev/null | grep -vE '\.so$'); do
  real=$(readlink -f "$S/lib/$son"); put "$real" "$DEV/lib/$son"
done

echo "=== 2. gst media plugins -> $GST ==="
for p in libgstrtp.so libgstvpx.so libgstopus.so; do
  [ -f "$S/lib/gstreamer-1.0/$p" ] && put "$S/lib/gstreamer-1.0/$p" "$GST/$p" || echo "  !! staging missing $p (run build-gst-webrtc-media.sh)"
done

echo "=== restart atlas, clear gst registry, wait for socket ==="
cat <<'SH' | novacom run file://bin/sh
rm -f /tmp/bs-atlas.log /tmp/yapserver.atlas /tmp/atlas-gstreg.bin
start atlas 2>/dev/null; sleep 5
i=0; while [ $i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=$((i+1)); done
echo "socket up after $((i+5))s; BS=$(ps -ef|grep -c '[B]rowserServer-atlas')"
SH
echo "=== done. Verify RTCPeerConnection at webrtc.github.io/samples/src/content/peerconnection/pc1/ ==="
