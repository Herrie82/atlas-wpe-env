#!/bin/sh
# Enable real WebProcess core dumps for Atlas crash debugging (re-run after each reboot —
# /etc/event.d/minicore2 resets these on boot). The stock minicore pipes to /usr/sbin/minicore2
# which is absent on this device, so crashes produce NO dump; this disables that and uses core_pattern.
DR=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252
WP=$DR/libexec/wpe-webkit-2.0/WPEWebProcess
echo "" > /proc/sys/kernel/minicore_pattern
echo '/media/internal/corefiles/%e.%p.core' > /proc/sys/kernel/core_pattern
mkdir -p /media/internal/corefiles
if [ ! -f "$WP.real" ]; then cp -a "$WP" "$WP.real"; fi
cat > "$WP" <<'WRAP'
#!/bin/sh
ulimit -c unlimited
exec /media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/libexec/wpe-webkit-2.0/WPEWebProcess.real "$@"
WRAP
chmod +x "$WP"
echo "core dumps enabled: core_pattern=[$(cat /proc/sys/kernel/core_pattern)] wrapper=$(head -n1 $WP)"
