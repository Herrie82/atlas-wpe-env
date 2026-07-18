#!/bin/bash
# Pull the newest WPEWebProcess core off the device and print a symbolicated backtrace.
# Requires: core-dump infra enabled on device (enable-cores.sh) + the device running the
# UNSTRIPPED libWPEWebKit that matches host $B/lib (redeploy-webkit.sh deploys unstripped).
#   Usage: ./get-core-bt.sh            # newest core
#          ./get-core-bt.sh <name>     # specific core file name in /media/internal/corefiles
set -e
WPE=/home/herrie/webos/wpe
B="$WPE/build/wpewebkit-2.52.4/_b"
DEVCORES=/media/internal/corefiles
OUT=/tmp/atlas-core; mkdir -p "$OUT"

# 1. find newest core on device (or use the arg)
NAME="${1:-}"
if [ -z "$NAME" ]; then
  NAME=$(cat <<'SH' | novacom run file://bin/sh 2>/dev/null | tail -1
ls -t /media/internal/corefiles/*.core 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null
SH
)
fi
[ -z "$NAME" ] && { echo "no core found on device (crash not captured?)"; exit 1; }
echo "=== core: $NAME ==="

# 2. gzip on device (cores are big) then pull
cat <<SH | novacom run file://bin/sh 2>/dev/null
gzip -c "$DEVCORES/$NAME" > /tmp/$NAME.gz 2>/dev/null && echo "gzipped $(stat -c%s /tmp/$NAME.gz 2>/dev/null) bytes"
SH
novacom get file:///tmp/$NAME.gz > "$OUT/$NAME.gz"
gunzip -f "$OUT/$NAME.gz"
echo "pulled -> $OUT/$NAME"

# 3. backtrace with gdb-multiarch against the unstripped host lib
gdb-multiarch -q -batch \
  -ex "set solib-search-path $B/lib:$B/bin:$WPE/staging-glibc-252/lib" \
  -ex "set sysroot $WPE/staging-glibc-252" \
  -ex "core-file $OUT/$NAME" \
  -ex "thread apply all bt" 2>&1 | sed -n '1,120p'
