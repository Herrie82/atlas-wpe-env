#!/bin/bash
# Build a complete, installable Atlas Web ipk from this checkout — portable reproduction of
# full-restore-atlas.sh + build-ipk.sh, without the dependency on Herrie's private tree
# ($WPE/env-glibc-gcc125.sh, staging-glibc-252, the wpewebkit _b build dir, camera-path-a).
#
#   source env-atlas-cross.sh
#   ./build-ipk-atlas.sh                 # -> atlas-browser-app/ipks/<target>/org.webosports.app.atlas_<ver>_all.ipk
#   ./build-ipk-feed.sh / ./build-ipk-standalone.sh   # the two distribution targets (see ATLAS_PKG_TARGET)
#   DOSTRIP=0 ./build-ipk-atlas.sh       # keep symbols (bigger ipk, for gdb)
#
# WHAT COMES FROM WHERE  (see BUILDING.md §7):
#   built from source here .. BrowserServer-atlas, libWPEBackend-atlas.so
#   this repo ............... boot wrapper, NPAPI adapter, upstart jobs, ls2 roles, sensord, qspkd,
#                             postinst/prerm
#   atlas-browser-app ....... the Enyo front-end (appinfo/index/source/css/images/db)
#   reference deviceroot .... the WPE WebKit runtime (libWPEWebKit, WPEWebProcess/WPENetworkProcess,
#                             injected bundle), GStreamer stack, glibc-2.23 runtime, share/, webkit-data,
#                             fonts.conf/gstomx.conf, qcamd/qmicd
#
# The reference deviceroot is the engine runtime we have NOT yet rebuilt from source (WPE WebKit itself is
# a separate ~40 min build — build-webkit-252.sh). $DEVICEROOT_REF defaults to a tree pulled off a working
# device; keep that tarball, it is also your rollback artifact.
set -eu

ENV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOS="${REPOS:-$(dirname "$ENV_DIR")}"
APPSRC="${APPSRC:-$REPOS/atlas-browser-app}"
BLD="${BLD:-$REPOS/browserserver-build}"
BACKEND="${BACKEND:-$REPOS/atlas-wpe-backend/libWPEBackend-atlas.so}"
DEVICEROOT_REF="${DEVICEROOT_REF:-$HOME/atlas-device-backup/ref/org.webosports.app.atlas/deviceroot}"
# Built ipks land in the app repo's ipks/, which is TRACKED — the released artifacts are committed
# alongside the source they were built from. Per-target subdirectory is appended below.
OUT="${OUT:-$APPSRC/ipks}"
DOSTRIP="${DOSTRIP:-1}"
# Packaging target. The PAYLOAD (data.tar.gz) is identical either way — only control.tar.gz differs, so a
# feed can index the same engine bits without repacking anything.
#   standalone (default) : postinst restarts LunaSysMgr itself (WOQI / by-hand installs, where
#                          there is no installer to defer to). No Depends — nothing else to resolve them.
#   feed                 : postinst must NOT restart Luna (it would kill a batch installer running
#                          under it); instead declare PostInstallFlags=RestartLuna, and depend on the
#                          feed's OpenSSL 1.1 package so /usr/lib/ssl11 gets pulled in.
# Use the wrappers build-ipk-feed.sh / build-ipk-standalone.sh, or set ATLAS_PKG_TARGET here.
ATLAS_PKG_TARGET="${ATLAS_PKG_TARGET:-standalone}"
case "$ATLAS_PKG_TARGET" in feed|standalone) ;; *) echo "build-ipk-atlas: ATLAS_PKG_TARGET must be 'feed' or 'standalone' (got '$ATLAS_PKG_TARGET')" >&2; exit 1 ;; esac
# Depends: for a feed build. EMPTY BY DEFAULT, on purpose — the package does no environment checking,
# it just installs; qualifying environments is the FEED's job.
#
# Why not declare the OpenSSL 1.1 dependency here: ipkg enforces Depends against its own status file and
# has no notion of webOS version, so a hard dependency cannot be "3.0.5 only". webOS CE 3.1.0 bakes the
# TLS 1.3 stack (/usr/lib/ssl11) into the OS image and never registers org.webosarchive.tls-updates —
# the Modernize bundle is MaxWebOSVersion 3.0.9 and deliberately not offered there — so declaring it made
# ipkg refuse the install on a device that already had everything Atlas needs:
#     ERROR: Cannot satisfy the following dependencies for org.webosports.app.atlas:
#              org.webosarchive.tls-updates
# and abort mid-unpack, leaving the app directory half-created (empty deviceroot, no launcher icon).
#
# The FEED's Packages stanza carries `Depends: org.webosarchive.tls-updates` instead, and that qualifies
# itself: Preware's loadPackage() DROPS a package whose MaxWebOSVersion is older than the running OS
# (packages.js — not merely hides it), and getDependencies() only queues names it can find in the loaded
# set. So on 3.0.5 tls-updates loads and is pulled in; on 3.1.0 it is filtered out and the dependency
# resolves to nothing. Verified against Preware 1.9.18 on-device.
#
# Keep the feed stanza's Depends in PLAIN comma syntax — Preware's parser splits on "," only, so an
# alternation ("A | B") reaches it as one unknown package name and queues nothing, on 3.0.5 too.
#
# Set FEED_DEPENDS=... to emit a Depends line anyway (for a feed that resolves OpenSSL under its own
# name, or one whose index cannot carry dependency metadata).
FEED_DEPENDS="${FEED_DEPENDS:-}"
APPNAME=org.webosports.app.atlas
CRYPTO_DR="/media/cryptofs/apps/usr/palm/applications/$APPNAME/deviceroot"

die(){ echo "build-ipk-atlas: $*" >&2; exit 1; }
need(){ [ -e "$1" ] || die "missing $2: $1"; }

: "${TARGET:=arm-cortex_a8-linux-gnueabi}"
STRIP_BIN="${STRIP:-$TARGET-strip}"

need "$APPSRC/appinfo.json"                  "app front-end (set APPSRC=)"
need "$BLD/obj/BrowserServer-atlas"          "BrowserServer build (run build-browserserver-atlas.sh)"
need "$BACKEND"                              "backend .so (run build-backend-atlas.sh)"
need "$DEVICEROOT_REF/wpe-252/lib"           "reference deviceroot (set DEVICEROOT_REF=)"
need "$DEVICEROOT_REF/wpe-252/libexec/wpe-webkit-2.0/WPEWebProcess" "WPEWebProcess in reference deviceroot"

VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$APPSRC/appinfo.json" \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
: "${VER:=0.9.0}"

WORKROOT=$(mktemp -d); trap 'rm -rf "$WORKROOT"' EXIT
APP="$WORKROOT/usr/palm/applications/$APPNAME"
D="$APP/deviceroot/wpe-252"; A="$APP/deviceroot/atlas"
OUT="$OUT/$ATLAS_PKG_TARGET"   # same canonical filename per target, kept apart so one cannot clobber the other
mkdir -p "$APP" "$OUT"

echo "=== 1. app front-end from source ($APPSRC) ==="
for item in appinfo.json css db depends.js index.html source images \
            icon-1024x1024.png icon-256x256.png icon-48x48.png icon-64x64.png icon.png; do
  [ -e "$APPSRC/$item" ] && cp -a "$APPSRC/$item" "$APP/"
done
need "$APP/db/kinds" "db kinds (postinst registers them)"

echo "=== 2. engine deviceroot from reference ($DEVICEROOT_REF) ==="
cp -a "$DEVICEROOT_REF/." "$APP/deviceroot/"
rm -rf "$APP/faviconcache"                                    # runtime cruft, never ship it
rm -f  "$D/libexec/gstreamer-1.0/gst-plugin-scanner.pre-rpath.bak"
rm -rf "$D/libexec/wpe-webkit-1.0"                            # legacy WPE 1.0 API — engine uses 2.0

echo "=== 3. overlay the components built from source here ==="
cp -f "$BLD/obj/BrowserServer-atlas" "$D/BrowserServer-atlas"
cp -f "$BACKEND"                     "$D/lib/libWPEBackend-atlas.so"
echo "   BrowserServer-atlas  $(stat -c%s "$D/BrowserServer-atlas") bytes"
echo "   libWPEBackend-atlas.so $(stat -c%s "$D/lib/libWPEBackend-atlas.so") bytes"

# WPE WebKit itself, if it has been built from source (build-webkit-atlas.sh). Without this the engine
# runtime is whatever $DEVICEROOT_REF carried, i.e. prebuilt. Set WEBKIT_DESTROOT= to skip.
WEBKIT_DESTROOT="${WEBKIT_DESTROOT-$REPOS/webkit-build/destroot/var/atlas252}"
if [ -n "$WEBKIT_DESTROOT" ] && [ -d "$WEBKIT_DESTROOT/lib" ]; then
  echo "=== 3b. overlay WPE WebKit built from source ($WEBKIT_DESTROOT) ==="
  # Copy the real files, not the .so -> .so.1 -> .so.1.9.8 symlink chain: cryptofs has no symlinks, so
  # the deviceroot keeps one real file per SONAME (same rule full-restore-atlas.sh follows).
  wk_real=$(readlink -f "$WEBKIT_DESTROOT/lib/libWPEWebKit-2.0.so.1")
  [ -f "$wk_real" ] || die "no libWPEWebKit in $WEBKIT_DESTROOT/lib"
  cp -f "$wk_real" "$D/lib/libWPEWebKit-2.0.so.1"
  cp -f "$WEBKIT_DESTROOT/libexec/wpe-webkit-2.0/WPEWebProcess"     "$D/libexec/wpe-webkit-2.0/"
  cp -f "$WEBKIT_DESTROOT/libexec/wpe-webkit-2.0/WPENetworkProcess" "$D/libexec/wpe-webkit-2.0/"
  cp -f "$WEBKIT_DESTROOT/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" \
        "$D/lib/wpe-webkit-2.0/injected-bundle/"
  # Web Inspector resources ship beside the library; keep them in step with it.
  [ -d "$WEBKIT_DESTROOT/lib/wpe-webkit-2.0" ] && cp -rf "$WEBKIT_DESTROOT/lib/wpe-webkit-2.0/." "$D/lib/wpe-webkit-2.0/"

  # Freshly built launchers point at the HOST-default interpreter (/lib/ld-linux.so.3 — on the device
  # that is the ancient system glibc 2.8) and carry no RPATH, because CMake drops the build RPATH at
  # install time unless CMAKE_INSTALL_RPATH is set. Left alone they die with
  #   "libWPEWebKit-2.0.so.1: cannot open shared object file"
  # while BrowserServer itself stays up, so the browser looks alive but renders nothing. Point them at
  # the bundled loader and engine lib dir, matching what the shipped binaries carry.
  command -v patchelf >/dev/null || die "patchelf required to fix the WebKit launchers"
  for b in "$D/libexec/wpe-webkit-2.0/WPEWebProcess" "$D/libexec/wpe-webkit-2.0/WPENetworkProcess"; do
    patchelf --set-interpreter "$CRYPTO_DR/wpe-252/lib/ld-linux.so.3" \
             --force-rpath --set-rpath "$CRYPTO_DR/wpe-252/lib:/usr/lib:/lib" "$b" \
      || die "patchelf failed on $(basename "$b")"
  done
  echo "   libWPEWebKit-2.0.so.1 $(stat -c%s "$D/lib/libWPEWebKit-2.0.so.1") bytes (from source)"
  echo "   patchelf'd WPEWebProcess/WPENetworkProcess to the bundled loader + engine rpath"
  ATLAS_WEBKIT_FROM_SOURCE=1
else
  echo "=== 3b. WPE WebKit: using the PREBUILT runtime from \$DEVICEROOT_REF ==="
  ATLAS_WEBKIT_FROM_SOURCE=0
fi

echo "=== 4. overlay artifacts committed in this repo ==="
cp -f "$ENV_DIR/ipk-build/pull/wrapper-BrowserServer" "$A/BrowserServer"   # upstart execs ./BrowserServer
mkdir -p "$APP/deviceroot/BrowserPlugins" "$APP/deviceroot/event.d" "$APP/deviceroot/ls2-roles"
cp -f "$ENV_DIR/ipk-build/pull/BrowserAdapterAtlas.so" "$APP/deviceroot/BrowserPlugins/"
cp -f "$ENV_DIR/ipk-build/pull/upstart-atlas"          "$APP/deviceroot/event.d/atlas"
cp -f "$ENV_DIR/ipk-build/pull/upstart-atlas-sensord"  "$APP/deviceroot/event.d/atlas-sensord"
cp -f "$ENV_DIR/roles/org.webosports.browserserver.json" "$APP/deviceroot/ls2-roles/"
cp -f "$ENV_DIR/roles/org.webosports.qmicd.json"         "$APP/deviceroot/ls2-roles/"
[ -f "$ENV_DIR/sensord/atlas-sensord" ] && cp -f "$ENV_DIR/sensord/atlas-sensord" "$A/atlas-sensord"
[ -f "$ENV_DIR/spk/qspkd" ]             && cp -f "$ENV_DIR/spk/qspkd" "$A/qspkd"
[ -f "$ENV_DIR/spk/libgstatlasqspksink.so" ] && \
  cp -f "$ENV_DIR/spk/libgstatlasqspksink.so" "$D/lib/gstreamer-1.0/libgstatlasqspksink.so"
[ -f "$ENV_DIR/mic/msm_media_case" ]    && cp -f "$ENV_DIR/mic/msm_media_case" "$APP/deviceroot/msm_media_case"
chmod 755 "$D/BrowserServer-atlas" "$A/BrowserServer" 2>/dev/null || true
chmod 755 "$A"/qcamd "$A"/qmicd "$A"/qspkd "$A"/atlas-sensord 2>/dev/null || true

echo "=== 5. sanity guards (fail loud rather than ship a broken browser) ==="
# GPU driver: ship all three names the engine asks for. postinst re-copies the DEVICE's own driver over
# these at install time, but the package must be self-sufficient — an ipk that omits them installs a
# browser that renders nothing if /usr/lib has no unversioned libEGL.so (the 0.9.8 field report).
# These come in via the reference deviceroot, which is only correct because it was pulled from a device
# where postinst had already staged them; guard it rather than keep relying on that provenance.
if [ -s "$D/lib/libEGL.so.1" ] && [ ! -s "$D/lib/libEGL.so" ]; then
  # The vendor libGLESv2 blob NEEDs the UNVERSIONED name (its own SONAME is libEGL.so too).
  cp -f "$D/lib/libEGL.so.1" "$D/lib/libEGL.so"
  echo "   staged unversioned libEGL.so (vendor libGLESv2 NEEDs it)"
fi
for gl in libEGL.so.1 libGLESv2.so.2 libEGL.so; do
  [ -s "$D/lib/$gl" ] || die "GPU driver $gl missing from the payload — a fresh install would render nothing.
       Copy the device's Adreno driver into the reference deviceroot:
         /usr/lib/libEGL.so -> \$DEVICEROOT_REF/wpe-252/lib/libEGL.so.1 (and libEGL.so)
         /usr/lib/libGLESv2.so -> \$DEVICEROOT_REF/wpe-252/lib/libGLESv2.so.2"
done
# The engine links versioned GPU sonames; postinst copies the device's real Adreno driver over these.
for f in "$D/lib/libWPEWebKit-2.0.so.1" "$D/libexec/wpe-webkit-2.0/WPEWebProcess" \
         "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" "$D/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so"; do
  need "$f" "engine runtime file"
done
# Adreno-220 WebGL fix (ANGLE dlopen("libGLESv2.so") fallback). Without it every WebGL page SIGSEGVs.
strings -a "$D/lib/libWPEWebKit-2.0.so.1" 2>/dev/null | grep -qx 'libGLESv2\.so' \
  || die "libWPEWebKit LACKS the Adreno WebGL fix (wpe-2.52.4-atlas-webgl-angle-fixes.patch) — stale runtime"
# WebRTC transport+media; a gap here ships a browser stuck on "Local Preview only".
miss=""
for p in libgstwebrtc.so libgstnice.so libgstdtls.so libgstsrtp.so libgstsctp.so libgstrtpmanager.so \
         libgstrtp.so libgstvpx.so libgstopus.so libgstogg.so libgstvorbis.so; do
  [ -f "$D/lib/gstreamer-1.0/$p" ] || miss="$miss $p"
done
[ -z "$miss" ] || die "WebRTC/codec plugins missing from the reference deviceroot:$miss"
# GIO content-type db — without mime.cache WebKit DOWNLOADS local html instead of rendering it.
[ -f "$D/share/mime/mime.cache" ] || echo "   WARN: no share/mime/mime.cache — file:// html may download"
# Our BrowserServer must already carry the bundled loader + device rpath (the build script links it so).
readelf -p .interp "$D/BrowserServer-atlas" 2>/dev/null | grep -q "wpe-252/lib/ld-linux.so.3" \
  || die "BrowserServer-atlas is not linked against the bundled loader"
# Same for the WebKit launchers. If these point at /lib/ld-linux.so.3 (the device's glibc 2.8) or have
# no RPATH, BrowserServer still starts and the browser renders NOTHING - the only symptom is
# "cannot open shared object file" buried in the engine log.
for b in "$D/libexec/wpe-webkit-2.0/WPEWebProcess" "$D/libexec/wpe-webkit-2.0/WPENetworkProcess"; do
  readelf -p .interp "$b" 2>/dev/null | grep -q "wpe-252/lib/ld-linux.so.3" \
    || die "$(basename "$b") does not use the bundled loader"
  readelf -d "$b" 2>/dev/null | grep -qE "RPATH|RUNPATH" \
    || die "$(basename "$b") has no RPATH — it will not find libWPEWebKit at runtime"
done
echo "   guards passed"

if [ "$DOSTRIP" = 1 ]; then
  echo "=== 6. strip the engine (DOSTRIP=0 to keep symbols) ==="
  # qcamd/qmicd/qspkd/atlas-sensord run under the SYSTEM glibc — leave them alone.
  find "$D/lib" "$D/libexec" -type f -name '*.so*' -exec "$STRIP_BIN" {} + 2>/dev/null || true
  "$STRIP_BIN" "$D/libexec/wpe-webkit-2.0/WPEWebProcess" \
               "$D/libexec/wpe-webkit-2.0/WPENetworkProcess" \
               "$D/BrowserServer-atlas" 2>/dev/null || true
fi

echo "=== 7. data.tar.gz ==="
INSTALLED_KB=$(du -sk "$WORKROOT/usr" | awk '{print $1}')
# Reproducible payload: stamp every member with one epoch and emit members in name order, so two builds
# of the same source produce a BYTE-IDENTICAL data.tar.gz. Without this the ~300 files we copy fresh each
# run carry the build clock, so every rebuild churns the ipk's md5 and a feed has to re-stanza a package
# whose contents did not actually change (measured: feed vs standalone build differed in 300 mtimes and
# ZERO bytes of content). It also makes the two packaging targets differ in control.tar.gz only.
#
# The stamp is the app repo's HEAD commit time, deliberately NOT a fixed constant: GStreamer invalidates
# its cached plugin registry by plugin .so mtime, so the stamp has to keep changing from release to
# release or an upgraded engine could be left running against a stale registry. Override with
# SOURCE_DATE_EPOCH; falls back to the build clock outside a git checkout (non-reproducible, as before).
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$APPSRC" log -1 --format=%ct 2>/dev/null || true)}"
if [ -n "$SOURCE_DATE_EPOCH" ]; then
  echo "   reproducible: stamping payload mtimes @$SOURCE_DATE_EPOCH (app HEAD)"
  ( cd "$WORKROOT" && tar czf "$OUT/data.tar.gz" --owner=0 --group=0 \
      --sort=name --mtime="@$SOURCE_DATE_EPOCH" ./usr )
else
  echo "   WARN: no git checkout at $APPSRC and no SOURCE_DATE_EPOCH — payload mtimes are the build clock"
  ( cd "$WORKROOT" && tar czf "$OUT/data.tar.gz" --owner=0 --group=0 ./usr )
fi

echo "=== 8. control.tar.gz ==="
CTRL="$WORKROOT/CONTROL"; mkdir -p "$CTRL"
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
if [ "$ATLAS_PKG_TARGET" = feed ]; then
  # Depends: normally NOT emitted — see the FEED_DEPENDS block above. The OpenSSL 1.1 requirement is
  # declared in the feed's Packages stanza, where MaxWebOSVersion can qualify it per OS version; ipkg
  # cannot, and a hard dependency here just blocks the install on webOS CE 3.1.0.
  if [ -n "$FEED_DEPENDS" ]; then echo "Depends: $FEED_DEPENDS" >> "$CTRL/control"; fi
  # Source: postinst deliberately does NOT restart LunaSysMgr in a feed build (it would kill a batch
  # installer running under it), so the reload is declared here for the installer to do once, at the end.
  # NOTE: Preware reads these flags from the FEED's Packages index Source block, not from this control —
  # a distributor must carry them into their stanza too. Emitting them keeps the ipk self-describing.
  # The display half of Source (Feed, Category, Title, FullDescription, Icon, DeviceCompatibility,
  # LastUpdated) stays out: that is per-feed catalog metadata, not a property of this package.
  cat >> "$CTRL/control" <<EOF
Source: { "PostInstallFlags":"RestartLuna", "PostUpdateFlags":"RestartLuna", "PostRemoveFlags":"RestartLuna" }
EOF
fi
cp "$ENV_DIR/ipk-postinst.sh" "$CTRL/postinst"; chmod 755 "$CTRL/postinst"
cp "$ENV_DIR/ipk-prerm.sh"    "$CTRL/prerm";    chmod 755 "$CTRL/prerm"
# Stamp the target into both scripts (they default to standalone when run straight from the repo).
for s in postinst prerm; do
  sed -i "s/^PKG_TARGET=.*/PKG_TARGET=$ATLAS_PKG_TARGET/" "$CTRL/$s"
  grep -q "^PKG_TARGET=$ATLAS_PKG_TARGET$" "$CTRL/$s" || die "failed to stamp PKG_TARGET into $s"
done
( cd "$CTRL" && tar czf "$OUT/control.tar.gz" --owner=0 --group=0 ./control ./postinst ./prerm )

# The SAME two scripts again, under the names webOS's own installer looks for. There are two install
# paths on this device and they disagree about who runs the control scripts:
#
#   Preware (org.webosinternals.ipkgservice) runs
#       /usr/bin/ipkg -o /media/cryptofs/apps -force-overwrite install <ipk>
#       IPKG_OFFLINE_ROOT=/media/cryptofs/apps /bin/sh <info>/<pkg>.postinst
#     -- i.e. it knows ipkg SKIPS postinst in offline-root mode ("Configuring <pkg> / (offline root
#        mode: not running <pkg>.postinst)") and runs the deferred script itself. control.tar.gz's
#        postinst/prerm are for this path.
#
#   com.palm.appinstaller (WebOS Quick Install, a tapped .ipk, installNoVerify) runs the same ipkg
#     command and then STOPS. It never runs the deferred postinst. What it does instead is extract the
#     ipk with `ar x` into a temp dir and run <tmpdir>/pmPostInstall.script (and pmPreRemove.script on
#     removal) as root -- webOS package format v2. With no such member it writes a 0-byte placeholder
#     and moves on, reporting SUCCESS.
#
# So a package that only ships postinst/prerm installs through that path with its ENGINE HALF MISSING:
# no BrowserAdapterAtlas.so, no /etc/event.d/atlas, no GPU driver staged, no db8 kinds. Atlas opens and
# renders nothing, which is exactly the "installs but cannot open a web page" report. `ar x` extracts
# every member, so shipping the scripts a second time as plain ar members covers that path too.
# Only ONE of the two ever runs for a given install; postinst/prerm are idempotent regardless.
cp "$CTRL/postinst" "$OUT/pmPostInstall.script"; chmod 755 "$OUT/pmPostInstall.script"
cp "$CTRL/prerm"    "$OUT/pmPreRemove.script";   chmod 755 "$OUT/pmPreRemove.script"

echo "=== 9. ar the ipk ==="
IPK="$OUT/${APPNAME}_${VER}_all.ipk"
printf '2.0\n' > "$OUT/debian-binary"
rm -f "$IPK"
( cd "$OUT" && ar rc "$(basename "$IPK")" debian-binary control.tar.gz data.tar.gz \
                     pmPostInstall.script pmPreRemove.script )
rm -f "$OUT/debian-binary" "$OUT/control.tar.gz" "$OUT/data.tar.gz" \
      "$OUT/pmPostInstall.script" "$OUT/pmPreRemove.script"

echo "== built: $IPK  ($(du -h "$IPK" | cut -f1), installed ~$((INSTALLED_KB/1024)) MB, v$VER) =="
if [ "${ATLAS_WEBKIT_FROM_SOURCE:-0}" = 1 ]; then
  echo "   engine: WPE WebKit built FROM SOURCE"
else
  echo "   engine: WPE WebKit is the PREBUILT runtime from \$DEVICEROOT_REF (build it with build-webkit-atlas.sh)"
fi
echo "   install via Preware / WebOS Quick Install (postinst must run as root)."
