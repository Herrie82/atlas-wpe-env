# Building the Atlas WPE engine from scratch

Reproducible instructions for cross-building the Atlas browser engine (the WPE WebKit backend,
`libWPEBackend-atlas.so`, and the `BrowserServer-atlas` host) for the HP TouchPad (webOS 3.0.5),
from a clean Linux host.

> **Status:** every step below is ✅ — run green here, from the committed scripts, and the resulting
> engine was A/B-tested against the shipped binary on a real TouchPad (§6).
>
> Two honest caveats. The toolchain build (§2) and the full ~400 MB device pull (§3 `device`) were not
> re-run from scratch for this pass — the toolchain is pinned by its defconfig, and the device pull's
> novacom `tar`/`get` mechanics were verified against a live device on a small subset. Everything else,
> including a clean-room sysroot rebuild and a full BrowserServer build against it, was.

## Repositories

| Repo | Role |
|------|------|
| [`atlas-browser-app`](https://github.com/Herrie82/atlas-browser-app) | Enyo UI front-end (builds with the webOS SDK alone) |
| [`atlas-wpe-backend`](https://github.com/Herrie82/atlas-wpe-backend) | `wpe-atlas-backend.c` → `libWPEBackend-atlas.so`; `BrowserPageWPE.{cpp,h}` (merged into BrowserServer); WebKit `patches/` |
| [`BrowserServer`](https://github.com/Herrie82/BrowserServer) | base `Src/` + `Yap/` IPC that `BrowserPageWPE` merges into |
| `atlas-wpe-env` (this repo) | build scripts, the toolchain recipe, deploy/packaging |

Clone them as siblings, e.g. under `~/Projects` or `~/webos/wpe`.

## The target ABI (why a custom toolchain)

The device's *system* glibc is ancient (2.8, Sourcery 2008) and the kernel is 2.6.35, but the engine
ships and runs against its **own bundled runtime** (binaries `patchelf`'d to a bundled loader). Confirmed
off a running device, that runtime is:

- **glibc 2.23** (crosstool-NG), soft-float ABI, loader **`ld-linux.so.3`**
- **armv7-a / cortex-a8 / neon**, `-mfloat-abi=softfp -mthumb`
- gcc **12.x** (C++23 for WebKit 2.52.4; BrowserServer must share the libstdc++ ABI)

A stock modern cross-toolchain won't do: its glibc is far newer, so its binaries need GLIBC symbols the
device's 2.23 lacks. Hence we build a device-matched toolchain.

## 1. Host prerequisites ✅

Debian/Ubuntu host:

```sh
sudo apt-get install -y build-essential gcc g++ make bison flex gperf \
  help2man texinfo libtool-bin automake autoconf gawk \
  libncurses-dev unzip rsync bzip2 wget patch git
```

## 2. Cross-toolchain via crosstool-NG ✅

The exact toolchain is pinned as a crosstool-NG **defconfig** in this repo:
[`toolchain/atlas-arm-crosstool.defconfig`](toolchain/atlas-arm-crosstool.defconfig)
(glibc 2.23, gcc 12, binutils 2.40, linux-2.6.32 headers, cortex-a8, neon, softfp).

```sh
git clone --depth 1 --branch crosstool-ng-1.26.0 \
    https://github.com/crosstool-ng/crosstool-ng
cd crosstool-ng
./bootstrap && ./configure --enable-local && make -j"$(nproc)"

# apply the Atlas toolchain recipe
cp /path/to/atlas-wpe-env/toolchain/atlas-arm-crosstool.defconfig defconfig
./ct-ng defconfig

# build it (~1–3 h; installs to ~/x-tools/arm-cortex_a8-linux-gnueabi)
./ct-ng build
```

Result: `~/x-tools/arm-cortex_a8-linux-gnueabi/bin/arm-cortex_a8-linux-gnueabi-{gcc,g++,...}`
(gcc 12.3.0, glibc 2.23). ~20 min on a 12-core host.

**Validate it runs on the device** (recommended smoke test). A C++ binary built with the arch flags and
`patchelf`'d to the engine's bundled runtime runs on the TouchPad:

```sh
arm-cortex_a8-linux-gnueabi-g++ -march=armv7-a -mtune=cortex-a8 -mfpu=neon \
    -mfloat-abi=softfp -mthumb -O2 -pthread hello.cpp -o hello        # note: glibc 2.23 → -pthread needed
patchelf --set-interpreter /var/atlas252/lib/ld-linux.so.3 --set-rpath /var/atlas252/lib hello
novacom put file:///tmp/hello < hello && novacom run file://bin/chmod -- 755 /tmp/hello
novacom run file:///tmp/hello          # → prints, using the bundled glibc 2.23 + libstdc++
```
(`/var/atlas252` is the postinst-created symlink to the engine's `wpe-252` dir.)

**Known issue — glibc 2.23 manual vs modern texinfo.** glibc 2.23 compiles fine, but `make install`
fails at the *documentation* step on hosts with texinfo ≥ 7 (`cannot stat '.../manual/libc.info*'`) —
the new `makeinfo` won't generate glibc 2.23's old manual. The recipe works around it with
`CT_GLIBC_EXTRA_CONFIG_ARRAY="MAKEINFO=:"` (already set in the defconfig), which tells glibc to treat
`makeinfo` as absent and skip the manual entirely. No effect on the produced libraries.

## 3. Staging sysroot ✅ (scripted)

The sysroot (`$STAGING`, default `~/atlas-staging`) holds the engine's **libraries** (to link against) and
matching **dev headers** (to compile against). It is built by one script:

```sh
atlas-wpe-env/stage-sysroot-atlas.sh all         # = headers + device + linklib
atlas-wpe-env/stage-sysroot-atlas.sh everything  # ... plus webkit-deps (needed only for §8)
```

or one phase at a time:

| Phase | What it does | Needs |
|-------|--------------|-------|
| `headers` | `include/` — pinned Debian armhf dev debs (extracted, never installed) + host Khronos/zlib + libwpe + this repo's `reconstructed-headers/` | network |
| `device`  | `lib/` (engine runtime, `deviceroot/wpe-252/lib`) and `rootfs/` (`/usr/lib` + `/lib`, ~84 MB, for `-rpath-link`) | a TouchPad running Atlas, over novacom |
| `linklib` | derives `linklib/` + the unversioned dev symlinks from `lib/` | — |
| `webkit-deps` | `webkitdeps/` — 65 pinned armhf dev packages (headers + `.pc`) for building WebKit itself, §8 | network |

Overridable: `STAGING`, `REPOS`, `DEB_CACHE`, `CRYPTO_DR`, `LIBWPE_TAG`.

**Header provenance.** Every dev deb is pinned by content hash and fetched from **snapshot.debian.org**,
which keeps every version forever (the regular pool 404s as sid moves on). The script verifies sha256
after download and refuses to continue on a mismatch. `dpkg-deb -x` extracts them without installing, so
nothing touches the host.

| deb | version | why |
|-----|---------|-----|
| `libwpewebkit-2.0-dev` | 2.52.5-1 | matches the engine's WebKit C API |
| `libqt4-dev` + `libqtwebkit-dev` | 4.8.7 / 2.3.4 | compile-only interface types (no Qt is linked) |
| `libglib2.0-dev` | 2.74.6-2+deb12u9 | glib headers + the **32-bit ARM** `glibconfig.h` (arch-dependent — must not come from the host) |
| `libsoup-3.0-dev` | 3.6.6-1 | soup3, as the engine uses |
| `libssl-dev` | 3.6.3-1 | OpenSSL 3 (generic + `arm-linux-gnueabihf` `opensslconf.h` overlay) |
| `libpng-dev` / `libpng12-dev` | 1.6.58-1 / 1.2.50 | png16 is what `OffscreenBuffer` links |

EGL/GLES2/KHR and zlib headers are arch-neutral, so the host's are used. `libwpe` headers come from the
1.16.0 release tag. `PmLogLib.h` is generated from `PmLogLib.h.in` into `$REPOS/PmLogLib`.

**Two things the `linklib` step gets right that are easy to get wrong by hand:**

1. **OpenSSL major.** `wpe-252/lib` ships *both* OpenSSL 1.1 and 3. The unversioned dev symlink is created
   from the **highest** real version (`sort -V`), so `-lssl` resolves to `libssl.so.3` — the engine's TLS
   stack. A naive glob picks `libssl.so.1.1` and silently links BrowserServer against the wrong major.
2. **Toolchain libs are excluded** from `linklib/` (`libc`, `libm`, `libpthread`, `libstdc++`, `libdl`,
   `librt`, `libresolv`, `libgcc_s`, the loader). The device copies are glibc 2.23 too, but letting them
   shadow the toolchain's own leaves `__libc_csu_init` undefined at link time.

> Verified: a clean-room `headers` run reproduces the previously hand-assembled `include/` tree
> **byte-for-byte**, and BrowserServer built against the scripted sysroot is identical to the hand-built
> one apart from the build timestamp and one baked `__FILE__` path (see *Build determinism* below).

## 4. Environment ✅

Source the portable env file (a reconstruction of the original, machine-specific `env-glibc-gcc125.sh`):

```sh
source /path/to/atlas-wpe-env/env-atlas-cross.sh
# honors overrides: TOOLCHAIN=... STAGING=...
# the existing build-*.sh scripts also accept it via:  export WPE_ENV=.../env-atlas-cross.sh
```

It sets `TARGET/CC/CXX/AR/…`, the `-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -mthumb`
flags, `STAGING`, and points `pkg-config` at the sysroot.

## 5. Build the components

**a) `libWPEBackend-atlas.so`** — ✅ verified (builds, and renders frames in the live engine on-device):

```sh
source atlas-wpe-env/env-atlas-cross.sh
atlas-wpe-env/build-backend-atlas.sh            # → atlas-wpe-backend/libWPEBackend-atlas.so
```

This portable script encodes what works: the arch flags, the staging `-I`/`-l` paths, and a post-link
`patchelf --replace-needed libEGL.so→libEGL.so.1 / libGLESv2.so→libGLESv2.so.2` (the device deploys the
Adreno driver under the versioned names, but its own SONAME is unversioned). The result's `NEEDED` list
matches the device's shipped backend exactly and exports `_wpe_loader_interface`. Validated by swapping
it into `/var/atlas252/lib`, restarting `atlas`, and confirming `[wpe-atlas] frame_rendered` in
`/media/ram/bs-atlas.log`.

**b) BrowserServer** — ✅ builds from source (all 22 objects compile + links to an ARM executable whose
`NEEDED` matches the deployed binary) **and validated on-device**: swapped into `wpe-252/`, it renders
identically to the shipped binary (A/B on `example.com`: frames 113 vs 115, WebProcess spawns 12 vs 13,
0 crashes each). This is where the `BrowserPageWPE.cpp` engine changes (e.g. the viewport fix) live.

```sh
source atlas-wpe-env/env-atlas-cross.sh
REPOS=~/Projects atlas-wpe-env/build-browserserver-atlas.sh   # → browserserver-build/obj/BrowserServer-atlas
```

Extra source repos to clone under `$REPOS` (headers only; nothing built):
[Herrie82/BrowserServer](https://github.com/Herrie82/BrowserServer),
[openwebos/luna-service2](https://github.com/openwebos/luna-service2),
[isis-project/WebKitSupplemental](https://github.com/isis-project/WebKitSupplemental),
[isis-project/pbnjson](https://github.com/isis-project/pbnjson),
[openwebos/PmLogLib](https://github.com/openwebos/PmLogLib).

All the headers and link libs this needs — `wpe-webkit-2.0`, Qt 4.8.7 + QtWebKit, soup3, OpenSSL 3,
png16, `PmLogLib.h`, the reconstructed QtWebKit stubs, and the device-pulled `lib/`/`rootfs/`/`linklib/` —
are staged by `stage-sysroot-atlas.sh` (§3). Nothing is installed on the host.

> **The `--unresolved-symbols=ignore-in-object-files` trap — read this before adding sources.**
> The link uses that flag to tolerate the unfinished QtWebKit hit-test stubs. It does **not** fail the
> build on a missing symbol: it binds the call to **address 0**, producing a binary that SIGSEGVs (`blx 0`)
> the moment that call is reached. This shipped once — `Src/Settings.cpp` calls
> `webOS::WebSettings::initSettings()`, which lives in `WebKitSupplemental/misc/weboswebsettings.cpp`,
> a file the build never compiled. Result: BrowserServer segfaulted inside `InitSettings()` on every
> startup, `/media/ram/bs-atlas.log` stayed 0 bytes, and upstart respawned it forever.
>
> Step 5 of `build-browserserver-atlas.sh` now disassembles the binary and **fails** on any `blx 0`
> outside a small allowlist. The allowlist (`asyncCmdGetImageInfoAtPoint`, `asyncCmdInspectUrlAtPoint`,
> `clearCache`, `BrowserPage::hitTest`) is still **latent breakage**: long-press image info / inspect
> and cache-clear will segfault until the upstream de-QtWebKit'ing is finished.
>
> `WebKitSupplemental/misc/*.cpp` is compiled with two deviations — no `-DQT_NO_KEYWORDS` (upstream uses
> Qt's `foreach`) and `wpe-shims/` first on the include path, which supplies a no-op QtWebKit
> `qwebsettings.h`. Stock QtWebKit lacks Palm's `setPluginSupplementalPath()` and `FullScreenEnabled`,
> and the WPE port must not link libQtWebKit at all; the settings that matter are applied to
> `WebKitSettings` in `BrowserPageWPE`.

**Debugging a startup crash.** `LD_DEBUG=libs` is usually a red herring (the library sets match the
shipped binary exactly). Get a real backtrace instead:

```sh
# on device
echo '/media/internal/core.%e.%p' > /proc/sys/kernel/core_pattern
ulimit -c unlimited          # the boot wrapper already sets this
# host, against the UNSTRIPPED binary
arm-cortex_a8-linux-gnueabi-gdb -q browserserver-build/obj/BrowserServer-atlas core.BrowserServer-a.NNN \
  -ex 'set solib-search-path <deviceroot>/wpe-252/lib' -ex 'bt 25'
```

Device gotchas: there is **no `timeout`** on the device (use `cmd & sleep N; kill $!`), and `novacom run`
does not relay stdout — push a script that redirects into a file and `novacom get` it afterwards.

**Two repo bugs found + worked around** (candidates for upstream PRs):
1. `CodeGen/BrowserYapCommandMessages.defs` `KeyDown`/`KeyUp` were stale — declared `uint16_t key,
   uint16_t modifiers` but `BrowserServer.cpp` implements `int key, int modifiers, int chr`. Fixed the
   `.defs` to match (CodeGen only understands `int`, not `int32_t`).
2. `BrowserPageWPE.h::hitTest()` returns a `QWebHitTestResult{}` — a compile-only QtWebKit type with no
   backing lib ("QtWebKit link TBD"). Left unresolved in the test link (never reached by a page load).

## 6. Deploy + test ✅

`build-browserserver-atlas.sh` already links with the bundled loader as the interpreter and the device
rpath baked in, so the binary needs no `patchelf` — just swap it in and restart the engine:

```sh
DR=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252

# 1. back up the shipped binary FIRST (/media/internal survives a restart)
novacom run file://bin/cp -- "$DR/BrowserServer-atlas" /media/internal/BrowserServer-atlas.bak

# 2. stop the engine (the upstart job, then any stragglers)
novacom run file://sbin/stop -- atlas
novacom run file://usr/bin/pkill -- -f WPEWebProcess
novacom run file://usr/bin/pkill -- -f BrowserServer-atlas

# 3. push + install
novacom put file:///media/internal/BrowserServer-atlas < browserserver-build/obj/BrowserServer-atlas
novacom run file://bin/cp -- /media/internal/BrowserServer-atlas "$DR/BrowserServer-atlas"
novacom run file://bin/chmod -- 755 "$DR/BrowserServer-atlas"

# 4. restart
novacom run file://sbin/start -- atlas
```

> novacom over USB gets flaky while the engine is restarting — expect to retry a step or two.

**Validated (2026-07-24):** the from-source (unmodified) BrowserServer renders identically to the shipped
binary. A/B on `example.com`: 113 vs 115 frames, 12 vs 13 `WPEWebProcess` spawns, 0 crashes each. (The
~13 spawns per load is normal Atlas behaviour — the shipped binary does it too.) Logs are in
`/media/ram/bs-atlas.log`. Restore with the `.bak` from step 1.

`deploy-252.sh` / `redeploy-webkit.sh` cover the fuller flows (WebKit runtime, test harness).

### The deadlock watchdog and `-d`

> **As of Atlas 0.9.10 the watchdog is OFF (`-d 0`).** The section below describes why it existed and how
> it was tuned; keep it for the day someone builds a detector that works. What went wrong is that
> `YapServer`'s "stalled **and** idle" gate — the very thing that made a short `-d` safe — is *also* an
> exact description of a healthy engine with nothing to do. The heartbeat counter is only proof the main
> loop is BUSY, never proof it is ALIVE, so an idle engine looks identical to a wedged one. Measured on
> webOS CE 3.1.0 with one idle card open and nobody touching the tablet:
>
>     BrowserServer-atlas: Deadlock detected; aborting! (13 cpu ticks in the last 90000ms)
>     BrowserServer-atlas: Deadlock detected; aborting! (155 cpu ticks in the last 90000ms)
>
> Two aborts in six minutes, each tearing down and reloading the user's cards. Note both are far *below*
> the 2250-tick busy threshold, so the busy-stall deferral never engages — being idle is what condemns it.
>
> **Nothing replaces it.** Atlas does not attempt to detect a hang — every heuristic tried either fired
> at healthy idle engines or missed real wedges. Clearing one is a user action: the **Restart Browser
> Engine** menu item, which asks `atlas-sensord` to restart the `atlas` job over a loopback control
> socket on `127.0.0.1:8442`. That routing is forced — the Enyo app runs as `luna` and cannot exec, and
> anything through BS is dead when BS is wedged; sensord is root and does not depend on BS.
>
> Re-enable `-d` here only with a detector that has the same property: a heartbeat that advances
> unconditionally (proving the loop is ALIVE, not that it is BUSY), so "counter stalled" alone is the
> signal and the CPU gate can be dropped.

**The GPU wedge is fixed (2026-08-23)** — and it was never the GPU. See
`atlas-wpe-backend/ARCHITECTURE.md` ("The GPU wedge — root cause") for the full account. In short, two
bugs in `libWPEBackend-atlas.so`'s UIProcess frame channel:

1. the backend closed, on the first frame, the socketpair end it had *returned to WebKit* — but WebKit
   adopts and closes that fd itself within milliseconds, so the backend's later `close()` hit whatever
   had reused the number (proven on-device: the main loop was found blocked in `recv()` on an fd whose
   peer was a WPEWebProcess's **WebKit IPC socket**);
2. the per-frame FRAME_ACK was never read by the WebProcess, so the blocking ack `send()` eventually
   parked the main loop once the socket buffer filled — "right after a good frame".

Both are in `wpe-atlas-backend.c`; rebuild with `build-backend-atlas.sh` and the ipk picks it up.
The history below is kept because the watchdog settings it explains are still in the tree.

The boot wrapper used to run the engine with `-d 90000`. That number was load-bearing for the **GPU wedge**
([#3](https://github.com/Herrie82/atlas-wpe-env/issues/3)) before the fix above: a wedge parks BrowserServer's main thread in
`futex_wait_queue_me` (or `__skb_recv_datagram`) with yap still accepting but nothing being serviced, and the yap deadlock watchdog
(`YapServer.cpp`) was the **only** thing that recovered it — it `abort()`s, upstart respawns, and the app's
cards reload themselves.
It used to be `-d 600000`, raised from the 15 s default because a memory-pressure GC stall would trip the
watchdog and abort a perfectly healthy engine. The cost was that a wedge took **14 min 30 s** to clear,
which every user reads as permanent. `YapServer.cpp` now gates the abort on the process **also being
idle**, which distinguishes the two cases the tick counter alone cannot:

| | main loop ticking | process CPU |
|---|---|---|
| GC / swap-in stall | stalled | pegs a core → abort deferred (bounded by `kMaxBusyStalls`) |
| GPU wedge | stalled | ~idle → abort immediately |

Measured on-device 2026-08-03 against a real wedge: `Deadlock detected; aborting! (528 cpu ticks in the
last 90000ms)` — 528 against a 2250-tick (25% of one core) threshold — wedge to serving pages again in
**63 s**.

Two practical notes: that message goes to **syslog** (`/var/log/messages`), *not* `bs-atlas.log`, so grep
the right file when checking whether the watchdog fired. And do not lower `-d` below ~90 s on an engine
built **before** this gate, or GC stalls will start killing healthy engines again.

To recover a wedge by hand now that the watchdog is off: `stop atlas; start atlas` (the cards reload
themselves, same as they did after an abort).

## 7. Package the installable ipk ✅

`build-ipk-atlas.sh` produces the real, installable `org.webosports.app.atlas_<ver>_all.ipk` (~99 MB
packed, ~209 MB installed). It is a portable reproduction of `full-restore-atlas.sh` + `build-ipk.sh`,
which cannot run outside Herrie's tree (they source the unpublished `env-glibc-gcc125.sh` and expect
`staging-glibc-252`, a `wpewebkit-2.52.4/_b` build dir, and `camera-path-a`).

```sh
source atlas-wpe-env/env-atlas-cross.sh
atlas-wpe-env/build-ipk-standalone.sh         # -> atlas-browser-app/ipks/standalone/org.webosports.app.atlas_<ver>_all.ipk
atlas-wpe-env/build-ipk-feed.sh               # -> atlas-browser-app/ipks/feed/... (Preware feed build)
DOSTRIP=0 atlas-wpe-env/build-ipk-atlas.sh    # keep symbols, for gdb
```

**Where each part of the payload comes from — read this before claiming "built from source":**

| Part | Source |
|------|--------|
| `BrowserServer-atlas`, `libWPEBackend-atlas.so` | **built from source here** (§5) |
| boot wrapper, NPAPI adapter, upstart jobs, ls2 roles, `atlas-sensord`, `qspkd`, postinst/prerm | committed in this repo |
| Enyo front-end (`appinfo`/`index.html`/`source`/`css`/`images`/`db`) | `atlas-browser-app` checkout |
| WPE WebKit (`libWPEWebKit`, `WPEWebProcess`/`WPENetworkProcess`, injected bundle) | **built from source** (§8), when a `build-webkit-atlas.sh` destroot is present |
| GStreamer stack, glibc-2.23 runtime, `share/`, `webkit-data`, `fonts.conf`/`gstomx.conf`, `qcamd`/`qmicd` | **`$DEVICEROOT_REF`** — a deviceroot pulled off a working device |

**As of 2026-07-25 WPE WebKit is also built from source** (§8) and `build-ipk-atlas.sh` ships it,
falling back to `$DEVICEROOT_REF` only when no build is present. The final line of its output states
which engine the package actually contains.

**Get `$DEVICEROOT_REF`** — do this *before* removing the browser from a device, it is also your rollback
artifact:

```sh
DR=/media/cryptofs/apps/usr/palm/applications
novacom run file://bin/tar -- czf /media/internal/atlas-app-backup.tgz -C "$DR" org.webosports.app.atlas
novacom get file:///media/internal/atlas-app-backup.tgz > atlas-app-backup.tgz
mkdir -p ~/atlas-device-backup/ref && tar xzf atlas-app-backup.tgz -C ~/atlas-device-backup/ref
novacom run file://bin/rm -- -f /media/internal/atlas-app-backup.tgz
# default DEVICEROOT_REF = ~/atlas-device-backup/ref/org.webosports.app.atlas/deviceroot
```

The script **fails loudly** rather than shipping a subtly broken browser. It checks the engine runtime
files exist, that `libWPEWebKit` carries the Adreno-220 WebGL fix (the `dlopen("libGLESv2.so")` ANGLE
fallback — without it every WebGL page SIGSEGVs the WebProcess), that the WebRTC transport/media and
Ogg/Vorbis/Opus GStreamer plugins are all present, and that `BrowserServer-atlas` really is linked against
the bundled `ld-linux.so.3`.

### Installing it

`postinst` must run as **root**, so install through Preware or WebOS Quick Install — *not* `palm-install`.
Since 0.9.10 the package carries its setup script under **both** names the two installers look for, so
either path completes on its own — see *Who runs the install scripts* below.
Headless over novacom, using the same appinstaller service those front-ends use:

```sh
novacom put file:///media/internal/atlas.ipk < ~/Projects/atlas-browser-app/ipks/standalone/org.webosports.app.atlas_0.9.9_all.ipk
# then, ON THE DEVICE (see the -n warning below):
luna-send -n 20 -f palm://com.palm.appinstaller/installNoVerify \
  '{"target":"/media/internal/atlas.ipk","subscribe":true,"uncompressedSize":214232}' > /tmp/reply.log 2>&1 &
LS=$!; i=0
while [ $i -lt 72 ]; do grep -q 'SUCCESS\|FAILED' /tmp/reply.log && break; sleep 5; i=$((i+1)); done
kill -9 $LS 2>/dev/null
```

> **`luna-send -n <n>` blocks until it receives exactly `n` replies.** `installNoVerify` emits only a
> handful, so `luna-send -n 20` never returns and the whole novacom session appears hung. Always run it
> in the background with a bounded poll, as above. (`remove` happens to emit exactly 3, which is why
> `-n 3` returns cleanly there.)
>
> **A standalone-target install restarts LunaSysMgr from its own postinst**, which kills the subscription
> `installNoVerify` is answering on — so the poll above often ends with
> `"com.palm.appinstaller is not running"` rather than `SUCCESS`, on an install that completed fine.
> Check the result on the device (below) instead of trusting the last subscription message.

#### Who runs the install scripts

`ipkg -o <root> install` — the command **both** installers use — does not run `postinst`. It says so:

    Configuring org.webosports.app.atlas
    (offline root mode: not running org.webosports.app.atlas.postinst)

The two front-ends handle that differently, and the difference is invisible until the browser renders
nothing:

| | what it does | what the package must ship |
|---|---|---|
| **Preware** (`org.webosinternals.ipkgservice`) | runs ipkg, then `IPKG_OFFLINE_ROOT=/media/cryptofs/apps /bin/sh <info>/<pkg>.postinst` itself | `postinst`/`prerm` in `control.tar.gz` |
| **`com.palm.appinstaller`** (WebOS Quick Install, tapped `.ipk`, `installNoVerify`) | runs ipkg and stops; separately `ar x`es the ipk and runs `<tmpdir>/pmPostInstall.script` (and `pmPreRemove.script` on removal) as root — webOS package format v2 | `pmPostInstall.script`/`pmPreRemove.script` as **ar members** |

With no `pmPostInstall.script` member the appinstaller writes a 0-byte placeholder into
`/media/cryptofs/apps/.scripts/<pkg>/` and reports **SUCCESS** for an install whose entire engine half is
missing. `build-ipk-atlas.sh` therefore emits the same two scripts twice, once under each name; only one
of them ever runs for a given install, and they are idempotent anyway.

Check afterwards that the engine half actually landed:

```sh
ls -l /usr/lib/BrowserPlugins/BrowserAdapterAtlas.so /etc/event.d/atlas /var/atlas252
ls -l /media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib/libEGL.so.1
#   ^ should be the DEVICE's Adreno driver (171517 bytes), not the bundled fallback
ps -ef | grep BrowserServer-atlas    # running, with -d 0
```

#### Uninstalling: kill the helper daemons first

`/media/cryptofs` is FUSE — unlinking a file a process still has open renames it to `.fuse_hiddenXXXXXXXX`
instead of removing it. The boot wrapper backgrounds `qcamd`/`qspkd`/`qmicd` as children of the engine, and
if the engine dies without reaping them they re-parent to init and keep holding the engine libs open. A
`prerm` that only kills `BrowserServer-atlas` therefore leaves an app directory `rm -rf` cannot remove:

    rm: can't remove '.../deviceroot/atlas': Directory not empty
    rm: can't remove '.../deviceroot/wpe-252/lib': Directory not empty

leaving an empty `deviceroot` skeleton that the next install unpacks on top of. `ipk-prerm.sh` kills all of
`BrowserServer-atlas qcamd qspkd qmicd atlas-sensord` (TERM then KILL) and sweeps `.fuse_hidden*`.

`postinst` copies the device's real Adreno driver over the versioned GPU sonames, creates the
`/var/atlas252` bridge symlink, installs the adapter/upstart/ls2-role/db8 files into the rootfs, registers
the db8 kinds, and starts the engine. It warns (does not fail) if `/usr/lib/ssl11/libssl.so.1.1` — the
community OpenSSL 1.1 package — is absent; without it HTTPS won't work.

---

### Build determinism

Two things keep builds from being bit-identical across hosts. Neither affects behaviour, but know about
them before you diff two binaries:

1. **A build timestamp** — `BrowserPageWPE.cpp` puts `__DATE__ " " __TIME__` in the `about:` diagnostics
   table, so every build differs by those 6 bytes.
2. **Absolute paths baked into `__FILE__`** — Qt's assert macros in `qt4/QtCore/qstring.h` embed the
   header's full path, so the length of your `$STAGING` path shifts `.rodata`.

Apart from those two strings, the same sources + the same pinned sysroot produce an identical binary —
that is how the `stage-sysroot-atlas.sh` output was verified against the hand-assembled sysroot.
Add `-ffile-prefix-map=$STAGING=/staging` (and a `SOURCE_DATE_EPOCH`-derived date) if you ever need
byte-reproducible output.

## 8. Building WPE WebKit itself

Only needed when changing WebKit source or its `patches/` — for backend/BrowserServer work you link
against the WebKit libs pulled in step 3. But this is what makes the build reproducible end-to-end
instead of depending on a prebuilt engine runtime.

```sh
atlas-wpe-env/stage-hosttools-atlas.sh           # ruby + unifdef, unprivileged
atlas-wpe-env/stage-sysroot-atlas.sh webkit-deps # 65 pinned armhf dev packages
source atlas-wpe-env/env-atlas-cross.sh
source atlas-wpe-env/hosttools-env.sh
atlas-wpe-env/apply-webkit-patches.sh            # extract 2.52.4 + the Atlas series, in order
atlas-wpe-env/build-webkit-atlas.sh configure
atlas-wpe-env/build-webkit-atlas.sh build        # ~8500 targets
```

> **`build-webkit-252.sh` is not this.** That script disables VIDEO, GSTREAMER, WEBRTC and WEBGL — the
> shipped engine plainly has all of them. It is an experiment, kept for reference. The feature set in
> `build-webkit-atlas.sh` was reconstructed from the shipped `libWPEWebKit-2.0.so.1`: its 65 `NEEDED`
> libraries and its symbol table (343 DFG references and zero CLoop → **JIT is on**, which is also why
> `wpewebkit-2.52.4-softfp-jit.patch` exists).

**Patch order matters.** `mediastream-camera` is authored on top of `mdpdetile-videosink`, and
`webrtc-mono-opus` on top of `webrtc-receive-av`; applying them alphabetically fails.
`apply-webkit-patches.sh` encodes the working order and is idempotent.

**Dependencies are headers, not builds.** The engine links what the device already ships, so
`webkit-deps` stages only dev headers and `.pc` files — 65 armhf packages pinned by version + sha256 in
[`webkitdeps.list`](webkitdeps.list), fetched through an unprivileged apt root spanning
bookworm/trixie/jammy. Versions track the **device's sonames**, not what is current:

| Package | Pinned to | Because |
|---------|-----------|---------|
| `libicu-dev` | **70.1** (jammy) | ICU mangles every symbol with its major (`u_strToUpper_70`); any other ICU will not link against the device's `libicuuc.so.70` |
| `libgstreamer1.0-dev` + plugins | **1.20.1** (jammy) | device ships GStreamer 1.20.7 |
| `libjpeg62-turbo-dev` | Debian | device ships `libjpeg.so.62`; Ubuntu's is `libjpeg.so.8` |
| `libcairo2-dev` | 1.18 (trixie) | device ships cairo 1.18.0 |

About half the list is *transitive pkg-config providers* (libpcre2, brotli, expat, libdw, libunwind,
orc, nghttp2, ffi, the X11 headers cairo's `.pc` references). They matter more than they look:

> **`pkg-config --modversion` succeeding proves nothing.** Only `--cflags --libs` walks the transitive
> `Requires:`. A missing `libpcre2-8.pc` surfaces as `Could NOT find Soup3: Found unsuitable version ".."`,
> because WebKit's Find modules silently fall back to scraping version headers when pkg-config fails.
> Also, `apt-get download` aborts the **entire batch** on one bad package name — fetch one at a time, or
> you will believe you staged things you did not.

**Four cross-build traps**, each worth a failed configure:

1. **`unset CFLAGS CXXFLAGS LDFLAGS` before cmake.** `env-atlas-cross.sh` aims them at the BrowserServer
   build, and `-L$STAGING/lib` puts the *device's* `libc.so` on the link line, shadowing the toolchain's
   and leaving `__libc_csu_init` undefined — CMake's trivial-program check fails outright.
2. **No `CMAKE_SYSROOT`.** `--sysroot` replaces the toolchain's own sysroot, so libc's headers stop
   resolving. Dependency headers arrive as explicit `-I` from pkg-config instead.
3. **`$STAGING/rootfs` must not be on the link path** — unlike the BrowserServer build. rootfs is the
   device's *system* tree (glibc 2.8). Because `linklib` deliberately excludes libc/libpthread, ld falls
   through to rootfs and picks up the 2.8 `libpthread.so.0`, whose `GLIBC_PRIVATE` symbols
   (`__default_sa_restorer_v2`, `h_errno`, …) do not exist in glibc 2.23.
4. **Add `/usr/include/<triplet>` explicitly.** Debian multiarch keeps `gpg-error.h`, `ffi.h`,
   `jconfig.h`, `openssl/` and `libxslt/` there, and pkg-config never emits that directory.

`CMAKE_INSTALL_PREFIX` is the **device** path (`/var/atlas252`, the short symlink `postinst` creates),
with `DESTDIR` staging the tree locally. That bakes correct `PKGLIBEXECDIR`/`PKGLIBDIR` at build time,
so the binary prefix-patching `deploy-252.sh` performs is no longer needed.
