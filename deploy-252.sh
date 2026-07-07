#!/bin/bash
# Assemble the standalone FRAME-DUMP TEST-HARNESS bundle for the glibc WPE WebKit stack.
# NOTE: this deploys the `frame-dump` repro harness (its run.sh execs frame-dump), NOT the shipping
# BrowserServer-atlas. The device runtime is BrowserServer-atlas via wrapper-BrowserServer + ipk-postinst.sh
# (see build-browserserver.sh / link-bs-252.sh / redeploy-test.sh). Use this only for isolated WPE repro.
# - Ships the glibc-2.23 runtime (device's old glibc lacks 2.23 symbols; 2.23 is forward-compat so the
#   device Adreno libEGL loads against it — proven by the standalone glibc EGL probe).
# - SYMLINK-FREE (/media/internal is FAT): every real .so copied under its SONAME.
# - Stripped to slim the push.
# - Preserves the WebKit install subdirs (libexec/wpe-webkit-2.0, lib/wpe-webkit-2.0/injected-bundle).
# - Binary-patches the baked install prefix: device / is read-only and no WEBKIT_EXEC_PATH override exists,
#   so the 36-char host prefix /home/herrie/webos/wpe/staging-glibc is rewritten IN-PLACE to the device
#   path padded to the SAME length with /. no-op components, so all baked paths resolve on-device.
# - EGL/GLESv2 sonames are staged at runtime by run.sh (copy of the device's real /usr/lib drivers).
set -e
WPE=/home/herrie/webos/wpe; . "${WPE_ENV:-$WPE/env-glibc.sh}"
GSR=$HOME/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot
OUT="${DEPLOY_OUT:-$WPE/deploy-glibc}"
# Engine runs from the app's cryptofs deviceroot. Interp/rpath (patchelf, no length limit) use the FULL
# cryptofs path; the baked-string prefix-patch below is length-limited to the host prefix, so it uses the
# short /var/atlas252 symlink (created by postinst) which points at the same cryptofs dir. NOT /media/internal.
CRYPTO_DR="${CRYPTO_DR:-/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot}"
DEVPATH="${DEVPATH:-$CRYPTO_DR/wpe-252}"
PREFIX_LINK="${PREFIX_LINK:-/var/atlas252}"
rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/libexec/wpe-webkit-2.0" "$OUT/lib/wpe-webkit-2.0/injected-bundle"

copy_soname(){ local f="$1" son
  son=$($TARGET-readelf -d "$f" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p' | head -1)
  [ -z "$son" ] && son=$(basename "$f")
  cp -f "$f" "$OUT/lib/$son"; $TARGET-strip "$OUT/lib/$son" 2>/dev/null || true
}

# 1. WPE + dependency libs (real files only; skip symlinks, EGL stubs, gstreamer/orc)
for f in "$STAGING"/lib/*.so*; do
  [ -L "$f" ] && continue
  case "$(basename "$f")" in libEGL.so*|libGLESv2.so*|libgst*|liborc*|libWPEWebKit-1.0.so*|libsoup-2.4.so*|libsoup-gnome-2.4.so*) continue;; esac
  copy_soname "$f"
done
# 2. glibc-2.23 runtime (soname-named; strip all but the loader)
for l in ld-linux.so.3 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2 libnss_compat.so.2; do
  cp -fL "$GSR/lib/$l" "$OUT/lib/$l"
  [ "$l" = ld-linux.so.3 ] || $TARGET-strip "$OUT/lib/$l" 2>/dev/null || true
done
# 3. C++/gcc runtime
for l in libstdc++.so.6 libgcc_s.so.1 libatomic.so.1; do copy_soname "$(readlink -f "$($CC -print-file-name=$l)")"; done

# 4. WebKit aux processes (keep subdir) + injected bundle + inspector + backend + harness
cp -f "$STAGING"/libexec/wpe-webkit-2.0/WPEWebProcess "$STAGING"/libexec/wpe-webkit-2.0/WPENetworkProcess "$OUT/libexec/wpe-webkit-2.0/"
cp -f "$STAGING"/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so "$OUT/lib/wpe-webkit-2.0/injected-bundle/"
$TARGET-strip "$OUT/lib/wpe-webkit-2.0/libWPEWebInspectorResources.so" "$OUT/lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so" 2>/dev/null || true
cp -f "$WPE/backend-atlas/frame-dump" "$OUT/frame-dump"
cp -f "$WPE/backend-atlas/libWPEBackend-atlas.so" "$OUT/lib/libWPEBackend-atlas.so"

# 5. interp + rpath -> shipped loader + lib dir (device libEGL via /usr/lib)
RP="$DEVPATH/lib:/usr/lib:/lib"
for b in "$OUT/frame-dump" "$OUT/libexec/wpe-webkit-2.0/WPEWebProcess" "$OUT/libexec/wpe-webkit-2.0/WPENetworkProcess"; do
  patchelf --set-interpreter "$DEVPATH/lib/ld-linux.so.3" --force-rpath --set-rpath "$RP" "$b"
done

# 6. binary-patch the baked host prefix -> device prefix padded to the same length with /. no-ops
python3 - "$OUT" <<'PY'
import sys, os, glob
OUT = sys.argv[1]
import os as _os
host = b'/home/herrie/webos/wpe/staging-glibc-252'
dev  = _os.environ.get('PREFIX_LINK', '/var/atlas252').encode()   # short symlink -> cryptofs deviceroot/wpe-252
pad = b''
while len(dev + pad) < len(host): pad += b'/.'
pad = pad[:len(host) - len(dev)]
devp = dev + pad
assert len(devp) == len(host), (len(devp), len(host))
n = 0
for f in glob.glob(OUT + '/**', recursive=True):
    if os.path.isfile(f) and not os.path.islink(f):
        d = open(f, 'rb').read()
        if host in d:
            open(f, 'wb').write(d.replace(host, devp)); n += 1
print(f"  prefix-patched {n} files: {devp.decode()}")
PY

# 7. run script: stage device EGL drivers under their sonames (FAT real copies) + env + frame-dump
cat > "$OUT/run.sh" <<EOS
#!/bin/sh
D=$DEVPATH
[ -f \$D/lib/libEGL.so.1 ]    || cp /usr/lib/libEGL.so    \$D/lib/libEGL.so.1
[ -f \$D/lib/libGLESv2.so.2 ] || cp /usr/lib/libGLESv2.so \$D/lib/libGLESv2.so.2
export LD_LIBRARY_PATH=\$D/lib:/usr/lib:/lib
export WPE_BACKEND_LIBRARY=\$D/lib/libWPEBackend-atlas.so
exec \$D/frame-dump "\$@"
EOS
chmod +x "$OUT/run.sh"
echo "deploy assembled: $(du -sh "$OUT" | awk '{print $1}'), $(ls "$OUT/lib"/*.so* | wc -l) libs  device=$DEVPATH"
