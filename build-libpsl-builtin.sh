#!/bin/bash
# Rebuild libpsl WITH the built-in Public Suffix List data and deploy it.
#
# WHY: libsoup's cookie jar calls psl_builtin() to decide cookie domain scoping (which registrable
# domain a cookie may be set for). The staging libpsl-0.21.5 was configured `-Dbuiltin=false`, so
# psl_builtin() returns NULL and every cookie check logs:
#     libsoup-WARNING: soup-tld: There is no public-suffix data available.
# (64+ per page load on e.g. teams.microsoft.com). Without PSL data cross-domain cookie scoping is
# weakened. Turning on builtin embeds the compiled DAFSA (~52KB) straight into libpsl.so — no runtime
# /usr/share/publicsuffix/*.dafsa file needed (the device has none).
#
# Verified: kDafsa symbol grows 0 -> ~52KB, deployed lib 13KB -> 67KB, and on-device the
# "no public-suffix data available" warnings drop from 64 to 0 during a real teams.microsoft.com load.
set -eu
WPE=/home/herrie/webos/wpe
. "$WPE/env-glibc-gcc125.sh"
SRC="$WPE/build/libpsl-0.21.5"
DR=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot

[ -f "$SRC/list/public_suffix_list.dat" ] || { echo "ERROR: PSL list data missing at $SRC/list/"; exit 1; }

# Reconfigure the existing meson build dir with builtin=true and rebuild just libpsl.
meson configure "$SRC/_b" -Dbuiltin=true
ninja -C "$SRC/_b" src/libpsl.so.5.3.5

# Stage + strip.
cp "$SRC/_b/src/libpsl.so.5.3.5" "$WPE/staging-glibc-252/lib/libpsl.so.5.3.5"
"$TARGET-strip" "$WPE/staging-glibc-252/lib/libpsl.so.5.3.5"

# Sanity: the built-in DAFSA must be present now.
sz=$("$TARGET-nm" -S --defined-only "$SRC/_b/src/libpsl.so.5.3.5" 2>/dev/null | awk '/ kDafsa$/{print $2}')
echo "kDafsa size = 0x${sz:-0} (must be non-zero)"
[ -n "${sz:-}" ] || { echo "ERROR: kDafsa not embedded — builtin data missing"; exit 1; }

# Deploy to the device (single soname file). BS must be stopped or the file is locked:
#   novacom run file://sbin/stop -- atlas
echo "Deploy with:"
echo "  novacom put file://$DR/wpe-252/lib/libpsl.so.5 < $WPE/staging-glibc-252/lib/libpsl.so.5.3.5"
