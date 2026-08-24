#!/bin/bash
# Build the Atlas ipk for STANDALONE distribution — WebOS Quick Install, a direct download, or installing
# by hand. No package manager is involved, so the package has to finish the job itself:
#   - postinst restarts LunaSysMgr itself (it must reload before it can see the browser plugin). prerm
#     never does, on either target -- it runs from inside LunaSysMgr before `ipkg remove`.
#     Nothing is running under it to be killed, and there is no installer to defer the reload to.
#   - No Depends. There is no feed to resolve them, and a dependency nothing can satisfy just makes the
#     install fail. OpenSSL 1.1 (/usr/lib/ssl11) still has to be installed separately for HTTPS to work —
#     postinst warns when it is missing.
#
#   ./build-ipk-standalone.sh   # -> atlas-browser-app/ipks/standalone/org.webosports.app.atlas_<ver>_all.ipk
set -eu
exec env ATLAS_PKG_TARGET=standalone "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/build-ipk-atlas.sh" "$@"
