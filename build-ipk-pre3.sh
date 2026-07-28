#!/bin/bash
# Build a complete, installable HP Pre 3 Atlas ipk by REUSING an existing TouchPad ("tenderloin") ipk's
# engine bundle — Pre 3 and TouchPad share ABI, so libWPEWebKit / WPEWebProcess / GStreamer /
# BrowserServer-atlas / the adapter are all reused unchanged. We only:
#   - swap in the pre3-lowmem app front-end (low-memory profile + phone CSS),
#   - add deviceroot/atlas/device-profile (the 512MB engine tuning),
#   - patch the boot wrapper to source that device-profile,
#   - bump the package version.
# Result: org.webosports.app.atlas_<ver>_all.ipk, structurally identical to the TouchPad ipk (Path A).
#
#   TP_IPK=/path/to/touchpad.ipk  APPSRC=/path/to/atlas-browser-app(@pre3-lowmem)  ./build-ipk-pre3.sh
set -euo pipefail

ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$ENV_DIR")}"
TP_IPK="${TP_IPK:-/home/herrie/webos/wpe/ipk-build/org.webosports.app.atlas_0.9.6_all.ipk}"
APPSRC="${APPSRC:-$REPOS/atlas-browser-app}"
PROFILE="${PROFILE:-$ENV_DIR/ipk-build/pull/device-profile-pre3}"
OUT="${OUT:-/home/herrie/webos/Pre3/atlas-pre3-build}"
APPNAME=org.webosports.app.atlas

for f in "$TP_IPK" "$APPSRC/appinfo.json" "$PROFILE"; do [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$APPSRC/appinfo.json" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
: "${VER:=0.9.7}"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "=== 1. unpack TouchPad ipk (reused engine): $TP_IPK ==="
( cd "$W" && ar x "$TP_IPK" && mkdir data ctl && tar xzf data.tar.gz -C data && tar xzf control.tar.gz -C ctl )
APP="$W/data/usr/palm/applications/$APPNAME"
[ -d "$APP/deviceroot/wpe-252" ] || { echo "no engine deviceroot in ipk" >&2; exit 1; }

echo "=== 2. swap in pre3-lowmem app front-end (keep deviceroot) ==="
for item in appinfo.json css db depends.js index.html source images \
            icon-1024x1024.png icon-256x256.png icon-48x48.png icon-64x64.png icon.png; do
  rm -rf "$APP/${item:?}"
  [ -e "$APPSRC/$item" ] && cp -a "$APPSRC/$item" "$APP/"
done

echo "=== 3. add device-profile + patch wrapper to source it ==="
cp -a "$PROFILE" "$APP/deviceroot/atlas/device-profile"
WRAP="$APP/deviceroot/atlas/BrowserServer"
if ! grep -q 'device-profile' "$WRAP"; then
  # insert the source line immediately before the final exec of the engine
  awk '/^exec .*BrowserServer-atlas/ && !done { print "[ -r \"$ATLAS/device-profile\" ] && . \"$ATLAS/device-profile\"  # Pre 3 low-memory tuning"; done=1 } { print }' "$WRAP" > "$WRAP.new"
  mv "$WRAP.new" "$WRAP"; chmod 755 "$WRAP"
fi

echo "=== 4. control: version + description ==="
sed -i -E "s/^Version: .*/Version: $VER/" "$W/ctl/control"
sed -i -E "s/for webOS \(HP TouchPad\)\./for webOS (HP Pre 3, 512MB low-memory profile)./" "$W/ctl/control"

echo "=== 5. repack ipk ==="
mkdir -p "$OUT"
( cd "$W/data" && tar czf "$W/data.tar.gz" --owner=0 --group=0 ./* )
( cd "$W/ctl"  && tar czf "$W/control.tar.gz" --owner=0 --group=0 ./* )
echo "2.0" > "$W/debian-binary"
IPK="$OUT/${APPNAME}_${VER}_pre3.ipk"
rm -f "$IPK"
( cd "$W" && ar rc "$IPK" debian-binary control.tar.gz data.tar.gz )
echo "=== done: $IPK  ($(stat -c%s "$IPK") bytes) ==="
