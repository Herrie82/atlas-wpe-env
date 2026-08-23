# atlas-wpe-env

Build environment, cross-build scripts, toolchain recipe, and deploy/packaging for the **Atlas**
browser engine on the HP TouchPad (webOS 3.0.5 and webOS CE 3.1.0) — the WPE WebKit backend,
`BrowserServer-atlas`, and the self-contained IPK. One IPK installs on both OS versions; see
[BUILDING.md § Who runs the install scripts](BUILDING.md#who-runs-the-install-scripts) and the
`FEED_DEPENDS` note in `build-ipk-atlas.sh` for why that took three separate packaging fixes.

- **[BUILDING.md](BUILDING.md)** — reproduce the whole engine build from a clean host (toolchain →
  sysroot → components → deploy).
- **[toolchain/atlas-arm-crosstool.defconfig](toolchain/atlas-arm-crosstool.defconfig)** — the pinned
  crosstool-NG recipe for the device-matched cross toolchain (glibc 2.23, gcc 12, cortex-a8/neon/softfp).
- **[env-atlas-cross.sh](env-atlas-cross.sh)** — portable cross-build environment (`source` it, or point
  the build scripts at it via `WPE_ENV=`).
- **[stage-sysroot-atlas.sh](stage-sysroot-atlas.sh)** — builds the staging sysroot: hash-pinned Debian
  armhf dev headers (extracted, never installed), the device-pulled link libs, and the `linklib/` farm.
- **[build-ipk-atlas.sh](build-ipk-atlas.sh)** — assembles the installable ipk (app front-end + engine
  deviceroot + the from-source components), with guards against shipping a broken engine.
- **[wpe-shims/](wpe-shims/)** — no-op QtWebKit headers so the WPE port can compile the WebKitSupplemental
  settings code without stock QtWebKit (and without linking libQtWebKit).
- **[CODE-AUDIT.md](CODE-AUDIT.md)** — engine code audit notes.

Related repos: [atlas-browser-app](https://github.com/Herrie82/atlas-browser-app) (UI),
[atlas-wpe-backend](https://github.com/Herrie82/atlas-wpe-backend) (WPE backend + `BrowserPageWPE`),
[BrowserServer](https://github.com/Herrie82/BrowserServer) (IPC host base).
