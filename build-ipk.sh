#!/bin/bash
# Build a COMPLETE, self-contained Atlas ipk: app front-end + the whole WPE engine deviceroot + the
# NPAPI adapter + upstart job + LunaService role file + db8 config. Installing it (via Preware / WebOS
# Quick Install, which runs postinst as root) lays everything down through ipk-postinst.sh — engine in
# place on cryptofs, adapter/upstart/role/db into the rootfs, /var/atlas252 bridge, hub rescan. This is
# the "so we never have to hand-restore again" package.
#
# Reuses full-restore-atlas.sh to assemble the app tree (front-end from atlas-browser-app, engine libs
# one-per-SONAME from staging, role/adapter/upstart bundled), then wraps it as an ar ipk.
#   ./build-ipk.sh                 (strip engine — ~90MB ipk)
#   DOSTRIP=0 ./build-ipk.sh       (unstripped engine, ~2x, for gdb)
set -eu
WPE=/home/herrie/webos/wpe
ENV=/home/herrie/Documents/GitHub/atlas-wpe-env
APPSRC=/home/herrie/Documents/GitHub/atlas-browser-app
APPNAME=org.webosports.app.atlas
OUT=$WPE/atlas-restore
APP=$OUT/$APPNAME
IPKDIR=$WPE/atlas-ipk
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$APPSRC/appinfo.json" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
: "${VER:=0.9.0}"
IPK=$IPKDIR/${APPNAME}_${VER}_all.ipk
mkdir -p "$IPKDIR"

echo "=== 1. assemble the full app tree (front-end + deviceroot + role + adapter + upstart) ==="
DOSTRIP="${DOSTRIP:-1}" bash "$ENV/full-restore-atlas.sh" >/dev/null
[ -d "$APP/deviceroot/wpe-252" ] || { echo "assembly failed: no deviceroot"; exit 1; }

echo "=== 2. data.tar.gz  (root ./usr/palm/applications/$APPNAME) ==="
WORK=$(mktemp -d); mkdir -p "$WORK/usr/palm/applications"
cp -a "$APP" "$WORK/usr/palm/applications/$APPNAME"
INSTALLED_KB=$(du -sk "$WORK/usr" | awk '{print $1}')
( cd "$WORK" && tar czf "$IPKDIR/data.tar.gz" --owner=0 --group=0 ./usr )

echo "=== 3. control.tar.gz (control + postinst + prerm) ==="
CTRL=$(mktemp -d)
cat > "$CTRL/control" <<EOF
Package: $APPNAME
Version: $VER
Section: misc
Priority: optional
Architecture: all
Installed-Size: $INSTALLED_KB
Maintainer: WebOS Ports <webos-ports@googlegroups.com>
Description: Atlas Web — WPE WebKit 2.52 browser for webOS (HP TouchPad).
webOS-Package-Format-Version: 2
webOS-Packager-Version: 3.0.5b38
EOF
cp "$ENV/ipk-postinst.sh" "$CTRL/postinst"; chmod 755 "$CTRL/postinst"
cp "$ENV/ipk-prerm.sh"    "$CTRL/prerm";    chmod 755 "$CTRL/prerm"
( cd "$CTRL" && tar czf "$IPKDIR/control.tar.gz" --owner=0 --group=0 ./control ./postinst ./prerm )

echo "=== 4. ar the ipk (debian-binary + control + data) ==="
printf '2.0\n' > "$IPKDIR/debian-binary"
rm -f "$IPK"
( cd "$IPKDIR" && ar rc "$(basename "$IPK")" debian-binary control.tar.gz data.tar.gz )
rm -rf "$WORK" "$CTRL"
echo "built: $IPK  ($(du -h "$IPK" | awk '{print $1}'),  installed ~$((INSTALLED_KB/1024))MB, v$VER)"
echo "install on-device via Preware / WebOS Quick Install (runs postinst as root)."
