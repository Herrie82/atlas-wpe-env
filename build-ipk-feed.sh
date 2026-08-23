#!/bin/bash
# Build the Atlas ipk for distribution through a Preware-style FEED (e.g. WOSA Modernize).
#
# Differs from the standalone build ONLY in control.tar.gz — the engine payload is identical, so a feed
# can index these bits without repacking anything:
#   - postinst/prerm do NOT restart LunaSysMgr. Preware runs under LunaSysMgr, so restarting it mid-batch
#     kills the installer and abandons the rest of the dependency chain. The reload is declared instead as
#     PostInstallFlags/PostUpdateFlags/PostRemoveFlags = RestartLuna.
#   - NO Depends. The package does no environment checking, it just installs; qualifying environments is
#     the FEED's job. Atlas needs OpenSSL 1.1 (/usr/lib/ssl11), but that requirement is only true on
#     webOS 3.0.x — CE 3.1.0 bakes the stack into the OS image — and ipkg has no notion of OS version,
#     so a hard Depends here blocks the install on 3.1.0 instead of describing anything useful. Declare
#     it in the feed's Packages stanza (`Depends: org.webosarchive.tls-updates`, plain comma syntax),
#     where MaxWebOSVersion qualifies it: Preware drops a max-incompatible package at load time, so the
#     dependency pulls the bundle on 3.0.5 and resolves to nothing on 3.1.0. FEED_DEPENDS= overrides.
#
# NOTE: Preware reads the restart flags from the FEED's Packages index "Source" block, not from the ipk's
# control — copy them into your stanza as well.
#
#   ./build-ipk-feed.sh        # -> atlas-browser-app/ipks/feed/org.webosports.app.atlas_<ver>_all.ipk
set -eu
exec env ATLAS_PKG_TARGET=feed "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/build-ipk-atlas.sh" "$@"
