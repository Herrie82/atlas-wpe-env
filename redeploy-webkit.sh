#!/bin/bash
# Fast single-lib iteration for the WPE engine: incrementally rebuild libWPEWebKit-2.0.so.1.9.8, binary
# prefix-patch the baked host staging prefix -> the device /var/atlas252 symlink, deploy the ONE lib, and
# restart atlas. Much faster than the full deploy-252.sh. The device runs the UNSTRIPPED 95MB lib (so gdb /
# core symbols match), so no strip step. Engine can't be overwritten while running (ETXTBSY) -> stop first.
#   Usage: ./redeploy-webkit.sh          (build + deploy + restart)
#          NOBUILD=1 ./redeploy-webkit.sh  (skip ninja, just re-deploy the existing lib)
set -e
# Capture the deploy-strip flag BEFORE sourcing the env — the toolchain env exports STRIP=<strip-binary>
# (autotools convention), which would clobber a command-line STRIP=1. DOSTRIP holds our intent.
DOSTRIP="${STRIP:-0}"
WPE=/home/herrie/webos/wpe
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"
B="$WPE/build/wpewebkit-2.52.4/_b"
DEV=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
LIB=lib/libWPEWebKit-2.0.so.1.9.8

if [ "${NOBUILD:-0}" != "1" ]; then
  echo "=== ninja $LIB (incremental) ==="
  cd "$B"; export RUBYOPT="-r$WPE/ruby-compat.rb"
  time ninja "$LIB"
fi

echo "=== prefix-patch a copy (host staging -> /var/atlas252) ==="
TMP=$(mktemp /tmp/libwpe.XXXX.so)
cp -f "$B/$LIB" "$TMP"
# STRIP=1: ship the stripped lib (104MB -> ~67MB) — smaller mmap/relocation => faster cold WebProcess spawn.
# Default off so the on-device lib keeps symbols for gdb/core debugging (the baked staging-path string that
# the prefix-patch below rewrites survives --strip-unneeded, verified).
if [ "$DOSTRIP" = "1" ]; then
  "$STRIP" --strip-unneeded "$TMP"
  echo "  stripped deploy copy -> $(stat -c%s "$TMP") bytes"
fi
python3 - "$TMP" <<'PY'
import sys
host=b'/home/herrie/webos/wpe/staging-glibc-252'
dev=b'/var/atlas252'
pad=b''
while len(dev+pad)<len(host): pad+=b'/.'
pad=pad[:len(host)-len(dev)]
devp=dev+pad; assert len(devp)==len(host), (len(devp),len(host))
f=sys.argv[1]; d=open(f,'rb').read(); n=d.count(host)
open(f,'wb').write(d.replace(host,devp))
print(f"  prefix-patched {n} occurrences -> {devp.decode()}")
PY

echo "=== stop atlas + deploy ($(stat -c%s "$TMP") bytes) ==="
cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep -E 'BrowserServer-atlas|WPEWebProcess'|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo "stopped (BS left: $(ps -ef|grep BrowserServer-atlas|grep -v grep|wc -l))"
SH
novacom put file://$DEV/lib/libWPEWebKit-2.0.so.1 < "$TMP" && echo "deployed lib"
rm -f "$TMP"

# The injected bundle runs INSIDE the WebProcess and is compiled against WebKit's structs. It MUST be kept in
# lock-step with libWPEWebKit or ABI drift corrupts the WebProcess (e.g. an IPC struct like
# WebPageCreationParameters gaining a field under ENABLE(APPLICATION_MANIFEST) -> readyReadHandler memcpy SIGBUS).
# This step was historically MISSING, silently leaving an 8-day-stale bundle on device. No prefix-patch needed
# (0 staging-path refs; it resolves libWPEWebKit from the already-loaded process image).
BUNDLE_HOST="$B/lib/libWPEInjectedBundle.so"
BUNDLE_DEV="$DEV/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so"
if [ -f "$BUNDLE_HOST" ]; then
  novacom put file://"$BUNDLE_DEV" < "$BUNDLE_HOST" && echo "deployed injected bundle ($(stat -c%s "$BUNDLE_HOST") bytes)"
else
  echo "  WARN: injected bundle not found at $BUNDLE_HOST"
fi

echo "=== restart atlas ==="
cat <<'SH' | novacom run file://bin/sh
rm -f /tmp/bpwpe.log /tmp/bs-atlas.log
# Clear the cached GStreamer registry so any added/changed gst plugins (ogg/vorbis/opus, webrtc, etc.) get
# rescanned + registered. The registry now lives in cryptofs ($DEV/atlas-gstreg.bin, persistent across
# reboots) instead of /tmp — clear both so a redeploy always forces a clean rescan.
rm -f /tmp/atlas-gstreg.bin
rm -f /media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/atlas-gstreg.bin
start atlas 2>/dev/null; sleep 5
i=0; while [ $i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=$((i+1)); done
echo "socket up after $((i+5))s; BS=$(ps -ef|grep BrowserServer-atlas|grep -v grep|wc -l)"
SH
echo "=== done. touch /tmp/atlas_fs to enable fullscreen for the repro ==="
