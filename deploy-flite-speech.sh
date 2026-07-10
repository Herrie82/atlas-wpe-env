#!/bin/bash
# Deploy Flite speech-synthesis support: the rebuilt libWPEWebKit (ENABLE_SPEECH_SYNTHESIS=ON, USE_FLITE=ON)
# now NEEDs the Flite voice libs, so ship all libflite*.so to the engine lib dir ($D/lib, first in the
# WebProcess LD_LIBRARY_PATH). Flite was built --with-audio=none; PCM is played through WebKit's
# WebKitFliteSourceGStreamer backend, so no libasound dependency.
set -u
WPE=/home/herrie/webos/wpe; S=$WPE/staging-glibc-252
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
B="$WPE/build/wpewebkit-2.52.4/_b"
put(){ echo "  put $(basename "$2") ($(stat -c%s "$1") b)"; novacom put file://"$2" < "$1" || { echo "  !! put failed: $2"; return 1; }; }

echo "=== stop atlas ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo stopped
SH

echo "=== 1. Flite runtime libs -> $DEV/lib (deploy real files under SONAME) ==="
# NOTE: $S/lib/libflite*.so.1 are SYMLINKS -> libflite*.so.2.2. Must readlink -f to send the real
# file, else only the ~15-byte link text lands and libWPEWebKit can't resolve flite symbols.
for f in $(ls $S/lib/libflite*.so.1 2>/dev/null); do
  son=$(basename "$f")                   # e.g. libflite.so.1 (soname)
  put "$(readlink -f "$f")" "$DEV/lib/$son"
done

echo "=== 2. libWPEWebKit (prefix-patch host staging -> /var/atlas252, then put) ==="
echo "  NEEDED flite check:"; readelf -d "$B/lib/libWPEWebKit-2.0.so.1.9.8" 2>/dev/null | grep NEEDED | grep -i flite | sed 's/^/    /'
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

echo "=== restart atlas ==="
cat <<'SH' | novacom run file://bin/sh
rm -f /tmp/bs-atlas.log /tmp/yapserver.atlas
start atlas 2>/dev/null; sleep 5
i=0; while [ $i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=$((i+1)); done
echo "socket up after $((i+5))s"
SH
echo "=== done. Verify: speechSynthesis.getVoices() should list Flite voices; speak() should produce audio. ==="
