#!/bin/sh
# On-device: extract the restored Atlas app tar into cryptofs and reactivate. Rootfs mods (ssl11,
# BrowserAdapterAtlas.so, /etc/event.d/atlas, db8 kinds) survived the GC, so we only restore the
# cryptofs app + engine, recreate /var/atlas252, supply the GPU sonames, register the app, and start.
#
# Run DETACHED (nohup ... &) — cryptofs extraction is slow and outlasts the novacom connection:
#   nohup sh /tmp/activate.sh >/media/internal/atlas-activate.log 2>&1 &
# then poll /media/internal/atlas-activate.log for the RESTORE-DONE marker.
APPS=/media/cryptofs/apps/usr/palm/applications
APP=$APPS/org.webosports.app.atlas
DR=$APP/deviceroot
D=$DR/wpe-252
TAR=/media/internal/atlas-restore.tar.gz

echo "== 0. stop any running engine (frees busy files for rm) =="
stop atlas 2>/dev/null || true
killall -9 BrowserServer-atlas WPEWebProcess WPENetworkProcess 2>/dev/null || true
sleep 2

echo "== 1. clear old app dir (retry: cryptofs FUSE can be flaky) =="
[ -f "$TAR" ] || { echo "MISSING $TAR"; echo RESTORE-FAIL; exit 1; }
i=0; while [ -d "$APP" ] && [ $i -lt 5 ]; do rm -rf "$APP" 2>/dev/null; sync; i=$((i+1)); sleep 1; done
mkdir -p "$APPS"

echo "== 2. extract (slow — cryptofs is encrypted FUSE) =="
tar --no-same-owner -xzf "$TAR" -C "$APPS" 2>/dev/null || echo "  (tar ownership warnings ignored)"
sync
echo "  extracted: $(du -sh "$APP" 2>/dev/null | awk '{print $1}')"

echo "== 3. /var/atlas252 -> wpe-252 (baked-prefix bridge) =="
ln -sfn "$D" /var/atlas252

echo "== 4. GPU sonames from device Adreno driver (cryptofs has no symlinks -> copy) =="
cp -f /usr/lib/libEGL.so    "$D/lib/libEGL.so.1"
cp -f /usr/lib/libGLESv2.so "$D/lib/libGLESv2.so.2"

echo "== 5. perms + fresh gst registry =="
chmod 755 "$DR/atlas/BrowserServer" "$DR/atlas/qcamd" "$D/BrowserServer-atlas" 2>/dev/null || true
rm -f /tmp/atlas-gstreg.bin

echo "== 6. register app + start engine + reload LunaSysMgr =="
luna-send -n 1 -f luna://com.palm.applicationManager/rescan '{}' 2>/dev/null || true
start atlas 2>/dev/null || true
sleep 2
killall LunaSysMgr 2>/dev/null || true
sleep 3
echo "== procs: =="
ps -ef | grep -iE '[B]rowserServer-atlas|[q]camd' | awk '{print $2, $8}'
echo "== key files present? =="
for f in "$APP/appinfo.json" "$D/BrowserServer-atlas" "$D/lib/libWPEWebKit-2.0.so.1" "$DR/atlas/BrowserServer"; do
  [ -f "$f" ] && echo "  OK $(basename $f)" || echo "  MISSING $f"
done
echo RESTORE-DONE
