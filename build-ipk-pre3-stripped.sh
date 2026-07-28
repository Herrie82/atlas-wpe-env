#!/bin/bash
# Assemble the FEATURE-STRIPPED Pre 3 ipk: take the reuse Pre 3 ipk's deviceroot (app + device-profile +
# already-patched WebProcess launch paths) and swap in the stripped WebKit artifacts built by
# build-webkit-252-pre3.sh, then drop the now-dead GStreamer/media plugins to reclaim flash.
#
# ABI lockstep: feature-strip changes WebKit struct layouts, so libWPEWebKit + libWPEInjectedBundle +
# WPEWebProcess + WPENetworkProcess are ALL swapped together from _b_pre3 (a mismatched injected bundle =
# WebProcess SIGBUS — see redeploy-webkit.sh). libWPEWebKit is prefix-patched (host staging -> /var/atlas252)
# exactly like redeploy-webkit.sh; the WebProcess stubs get the same patchelf interp/rpath as deploy-252.sh.
#
# Run AFTER build-webkit-252-pre3.sh build completes.  Output: *_pre3-stripped.ipk
# NOTE: the patched cross-engine is UNVERIFIED on-device — keep the reuse ipk as the safe fallback.
set -euo pipefail
ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WPE="${WPE:-$HOME/webos/wpe}"
. "${WPE_ENV:-$WPE/env-glibc-gcc125.sh}"; S="$STAGING"
: "${TARGET:=arm-unknown-linux-gnueabi}"; STRIP_BIN="${STRIP:-$TARGET-strip}"
BP="$WPE/build/wpewebkit-2.52.4/_b_pre3"
DEST="$WPE/pre3-destroot"
BASE_IPK="${BASE_IPK:-/home/herrie/webos/Pre3/atlas-pre3-build/org.webosports.app.atlas_0.9.7_pre3.ipk}"
OUT="${OUT:-/home/herrie/webos/Pre3/atlas-pre3-build}"
APPNAME=org.webosports.app.atlas
CRYPTO_DR="/media/cryptofs/apps/usr/palm/applications/$APPNAME/deviceroot"
DEVPATH="$CRYPTO_DR/wpe-252"; PREFIX_LINK="/var/atlas252"

BUILT_LIB="$BP/lib/libWPEWebKit-2.0.so.1.9.8"
[ -f "$BUILT_LIB" ] || { echo "stripped lib not built yet: $BUILT_LIB (run build-webkit-252-pre3.sh build)"; exit 1; }
[ -f "$BASE_IPK" ] || { echo "base ipk missing: $BASE_IPK (run build-ipk-pre3.sh)"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "=== 1. unpack base (reuse) ipk ==="
( cd "$W" && ar x "$BASE_IPK" && mkdir data ctl && tar xzf data.tar.gz -C data && tar xzf control.tar.gz -C ctl )
DR="$W/data/usr/palm/applications/$APPNAME/deviceroot/wpe-252"

echo "=== 2. swap libWPEWebKit (prefix-patch + strip) ==="
TMP="$W/libwpe.so"; cp -f "$BUILT_LIB" "$TMP"; "$STRIP_BIN" --strip-unneeded "$TMP" || true
ATLAS_HOST_PREFIX="$S" PREFIX_LINK="$PREFIX_LINK" python3 - "$TMP" <<'PY'
import sys, os
host=os.environ['ATLAS_HOST_PREFIX'].encode(); dev=os.environ['PREFIX_LINK'].encode()
pad=b''
while len(dev+pad)<len(host): pad+=b'/.'
devp=(dev+pad)[:len(host)]; assert len(devp)==len(host)
f=sys.argv[1]; d=open(f,'rb').read(); n=d.count(host); open(f,'wb').write(d.replace(host,devp))
print(f"  prefix-patched {n} occurrences -> {devp.decode()}")
PY
cp -f "$TMP" "$DR/lib/libWPEWebKit-2.0.so.1"

echo "=== 3. swap injected bundle + WebProcess/NetworkProcess (ABI lockstep) ==="
IB_SRC=$(find "$BP" "$DEST" -name libWPEInjectedBundle.so 2>/dev/null | head -1)
cp -f "$IB_SRC" "$DR/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so"
"$STRIP_BIN" --strip-unneeded "$DR/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" || true
RP="$DEVPATH/lib:/usr/lib:/lib"
for name in WPEWebProcess WPENetworkProcess; do
  SRC=$(find "$BP" "$DEST" -name "$name" -type f 2>/dev/null | head -1)
  [ -n "$SRC" ] || { echo "  WARN: $name not found in build output"; continue; }
  cp -f "$SRC" "$DR/libexec/wpe-webkit-2.0/$name"
  "$STRIP_BIN" --strip-unneeded "$DR/libexec/wpe-webkit-2.0/$name" || true
  patchelf --set-interpreter "$DEVPATH/lib/ld-linux.so.3" --force-rpath --set-rpath "$RP" "$DR/libexec/wpe-webkit-2.0/$name"
  # WebProcess needs libEGL.so.1 as a direct NEEDED so the Adreno subdriver's eglSubDriverWait resolves
  # in the global scope (same bring-up fix as the full build; the base ipk's WebProcess is replaced here).
  [ "$name" = WPEWebProcess ] && patchelf --add-needed libEGL.so.1 "$DR/libexec/wpe-webkit-2.0/$name"
  echo "  patched $name"
done

echo "=== 4. drop dead GStreamer/media plugins + libs (video/webrtc gone) ==="
BEFORE=$(du -sm "$DR" | cut -f1)
rm -rf "$DR/lib/gstreamer-1.0" "$DR/libexec/gstreamer-1.0" 2>/dev/null || true
rm -f "$DR"/lib/libgst*.so* "$DR"/lib/libav*.so* "$DR"/lib/libswscale*.so* "$DR"/lib/libswresample*.so* \
      "$DR"/lib/libavcodec*.so* "$DR"/lib/libavformat*.so* "$DR"/lib/libavutil*.so* \
      "$DR"/lib/libvpx*.so* "$DR"/lib/libopus*.so* "$DR"/lib/libwebrtc*.so* 2>/dev/null || true
AFTER=$(du -sm "$DR" | cut -f1)
echo "  deviceroot ${BEFORE}MB -> ${AFTER}MB"

echo "=== 5. repack ==="
VER=$(grep -oE '^Version: .*' "$W/ctl/control" | awk '{print $2}')
sed -i -E "s/graphics bring-up\)\./graphics bring-up; feature-stripped engine)./" "$W/ctl/control"
( cd "$W/data" && tar --format=ustar -czf "$W/data.tar.gz" --owner=0 --group=0 ./* )
( cd "$W/ctl"  && tar --format=ustar -czf "$W/control.tar.gz" --owner=0 --group=0 ./* )
echo "2.0" > "$W/debian-binary"
IPK="$OUT/${APPNAME}_${VER}_pre3-stripped.ipk"; rm -f "$IPK"
( cd "$W" && ar rc "$IPK" debian-binary control.tar.gz data.tar.gz )
echo "=== done: $IPK  ($(stat -c%s "$IPK") bytes) ==="
