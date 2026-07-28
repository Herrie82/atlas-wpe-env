# Atlas WPE on the HP Pre 3 (webOS 2.2.4) — low-memory port

Goal: a **modern browser (WPE WebKit 2.52, real JS + OAuth2)** on the HP Pre 3 — 512 MB RAM,
single-core 1.4 GHz (MSM8x55), Adreno 205, 480×800, webOS 2.2.4 (mantaray). The bottleneck is **RAM**,
not CPU. Everything below exists to (a) never allocate the multi-screen-tall pan buffer, (b) keep a
single WebProcess with a low memory cap, and (c) avoid running a heavyweight tablet UI on top.

Feasibility was confirmed against the extracted rootfs
(`/home/herrie/webos/Pre3/nova-cust-image-mantaray.rootfs`): it has **Enyo 1.0**, the stock
`BrowserAdapter.so` + `BrowserServer` (so the NPAPI/yap plumbing exists), and `media/internal`. The
engine binaries are largely self-contained (bundled glibc/libs), so the TouchPad-built WPE engine is
expected to run on 2.2.4; the true unknowns are the GPU driver (Adreno 205 vs 220) and whether stock
LunaSysMgr 2.2.4 composites the NPAPI card the same way — both only testable on-device.

---

## Two paths

**Path B — engine swap under the stock Mojo browser (RECOMMENDED end state).**
Keep the stock webOS phone browser UI (`com.palm.app.browser`, already 480×800, already the default-
browser slot, lightweight Mojo) and swap ONLY the engine underneath it to WPE. No Enyo app on the
device. This is the right long-term phone experience and what you proposed.

Why it works (verified): the stock Mojo UI only speaks the **NPAPI JS contract** to the adapter plugin;
the yap wire protocol is internal to the adapter+server pair (they ship together), so yap divergence is
irrelevant. The Atlas adapter already implements ~95% of the NPAPI methods/callbacks the stock
framework `webview` widget uses. The only required change is registering the adapter under the stock
mime/socket.

**Path A — Enyo Atlas app, low-memory profile (good FIRST smoke test).**
Ship the existing Atlas Enyo app with a global low-memory profile. Use this first because
Atlas-app + Atlas-adapter + Atlas-server is the **known-good** combination (it works on the TouchPad),
so if it renders on the Pre 3 you've proven *the WPE engine runs on 2.2.4 hardware* — independent of
the Mojo NPAPI-contract unknown. Then move to Path B for the production UI.

Suggested order: **smoke-test with A → switch to B.**

---

## What changed (all on `pre3-lowmem` branches; nothing merged to master/main)

| Repo | Branch | Change |
|------|--------|--------|
| `atlas-browser-app` | `pre3-lowmem` | Global low-memory profile: hardware autodetect (`AtlasEngineOverride.js` sets `window.__atlasLowMem` from screen size/model), every card born `simpleMode`, `lowMemoryMode` pref + Preferences toggle, single-card "open in new card", `css/phone.css` (480×800). |
| `atlas-wpe-backend` | `pre3-lowmem` | `bpwpe_force_low_mem()` — forces viewport-only rendering for **every** page (no `atlas-simple:` marker needed) when low-RAM or forced. **Essential for Path B** (Mojo UI can't send the marker). No-op on the TouchPad. Rebased on top of the now-committed Spotify-UA/cache work on `master`, so the branch has both. |
| `BrowserAdapter` | `pre3-lowmem` | Optional `-DATLAS_STOCK_BROWSER` build → registers stock mime `application/x-palm-browser` + client name `browser`. **Path B enabler.** Default build unchanged. |
| `atlas-wpe-env` | `pre3-lowmem` | `device-profile-pre3` (RAM/core/buffer overrides), wrapper sources `$ATLAS/device-profile` last, `upstart-browser-pre3` (BROWSERSERVER_NAME=browser), this doc. |

### Engine tuning applied on the Pre 3 (`ipk-build/pull/device-profile-pre3`)
- `JSC_forceRAMSize=96MB` (TouchPad 192) · `WEBKIT_NICOSIA_PAINTING_THREADS=1` (single core)
- `BPWPE_FORCE_SIMPLE=1` + `BPWPE_SIMPLE_SCREENS=1` → exact-viewport (mult=1) buffers
- `BPWPE_MEM_LIMIT=160` (TouchPad 480) · `BPWPE_NO_STRIP=0` (strip wins for viewport-sized rendering)
- RGB565 tiles + `MALLOC_ARENA_MAX=2` kept from Phase-1.

---

## Build

> **Already built (2026-07-28) → `~/webos/Pre3/atlas-pre3-build/`** (see its `DEPLOY-README.md`):
> the Path-A app ipk (`org.webosports.app.atlas_0.9.7_all.ipk`) and the Path-B stock adapter
> (`BrowserAdapter-stock-pre3.so`, mime `application/x-palm-browser`, verified). **Reuse the TouchPad
> engine as-is** — Pre 3 and TouchPad share ABI (ARMv7 softfp cortex-a8; adapter is classic armv6), so
> `libWPEWebKit`/`WPEWebProcess`/GStreamer/`BrowserServer-atlas` need **no rebuild**. Path B renders
> viewport-only via the adapter's `atlas-simple:` prepend + `device-profile` env, so even the server is
> reused. The steps below are only if you want to rebuild from scratch.

All builds are ARM cross-builds run from `atlas-wpe-env` (see the existing scripts). Check out the
`pre3-lowmem` branch in each repo first.

```sh
for r in atlas-browser-app atlas-wpe-backend BrowserAdapter atlas-wpe-env; do
  git -C ~/Documents/GitHub/$r checkout pre3-lowmem
done
```

> **Backend note:** the Spotify-UA + cache-on-tmpfs work is now committed on `atlas-wpe-backend/master`,
> and `pre3-lowmem` is rebased on top of it — so the branch contains **both** that work and the
> force-simple change. Just check it out. (The force-simple commit adds `bpwpe_force_low_mem()` near
> `lunaConfInt` and one call in `openUrl()`; it composes with the WIP's simple-mode prewarm teardown.)

1. **Engine server** (both paths) — includes the backend force-simple change:
   `./build-browserserver-atlas.sh` then link (see repo). Produces `BrowserServer-atlas`.
2. **Adapter**:
   - Path A: `./deploy-adapter.sh` as usual → `BrowserAdapterAtlas.so` (mime `x-atlas-browser`).
   - Path B: build the adapter with **`-DATLAS_STOCK_BROWSER`** added to its CXXFLAGS → a `.so` that
     registers `application/x-palm-browser`. Install it as the device's
     `/usr/lib/BrowserPlugins/BrowserAdapter.so` (back up the stock one first).
3. **App front-end** (Path A only): `palm-package ~/Documents/GitHub/atlas-browser-app`, or the full
   `build-ipk-atlas.sh`. No compile step. (No rename needed for the smoke test — keep the
   `org.webosports.app.atlas` id; Path B is what takes over `com.palm.app.browser`.)

> The stripped "Phase-3" engine (drop video/webrtc/webaudio/avif/jpegxl, `GPU_PROCESS=OFF`) is an
> **optimization, not required for the first test** — the current engine is self-contained and should
> run. When you want it, fork `build-webkit-252.sh` to a separate build dir + staging prefix and start
> from the LIVE `_b/CMakeCache.txt` flags (see the env map notes), then apply the drops. It buys the
> most headroom for the marginal heavy-SPA cases.

---

## Deploy + test

### Path A (Enyo smoke test)
1. Install the Atlas ipk (or drop the app front-end into its cryptofs app dir).
2. Deploy the engine deviceroot to the Pre 3; ship `device-profile-pre3` as `$ATLAS/device-profile`
   next to the wrapper; install `BrowserAdapterAtlas.so` → `/usr/lib/BrowserPlugins/`; install the
   `atlas` upstart job (BROWSERSERVER_NAME=atlas).
3. `killall LunaSysMgr`; launch Atlas.
4. **Expect:** the app opens phone-sized; `[Atlas] lowMemory autodetect=true` in the log; pages render
   viewport-only (no tall-buffer pan); an OAuth2 login (e.g. Google) completes. This proves the engine
   on 2.2.4.

### Path B (engine swap — production phone browser)
1. Leave the stock `com.palm.app.browser` app **as-is**.
2. Back up `/usr/lib/BrowserPlugins/BrowserAdapter.so`, install the `-DATLAS_STOCK_BROWSER` adapter in
   its place.
3. Deploy the engine deviceroot (with `device-profile`), install `upstart-browser-pre3` as
   `/etc/event.d/browser-wpe` (BROWSERSERVER_NAME=browser → `/tmp/yapserver.browser`), adjust its `cd`
   path to where you put the engine. Make sure the **stock** BrowserServer isn't also grabbing that
   socket.
4. `killall LunaSysMgr`; open the stock Web app.
5. **Expect:** the stock UI renders modern pages via WPE. Watch `/media/ram/bs-atlas.log` for the
   Connect handshake and `low-memory device/env -> forcing simple`.

**Path-B risks to watch (from the NPAPI compat review):**
- *Renders-but-blank* → the shared-buffer/offscreen paint handshake (`asyncCmdConnect 0x1000`
  sharedBufferKey/size ↔ `Painted 0x2000` blit) between the stock widget's offscreen path and the WPE
  backend. This is the deepest coupling; validate visually first.
- *Navigation stalls at start* → the widget gates the first `openURL` on `adapterInitialized` +
  `serverConnected` firing in order.
- *Preferences clear / text-select errors* → 4 NPAPI methods not yet exposed (`clearCache`,
  `clearCookies`, `ignoreMetaRefreshTags`, `setUserSelect`); non-fatal, listed as a follow-up in the
  BrowserAdapter commit. Add them to `names[]`/`methods[]` when convenient.

---

## Reality check
OAuth2 flows, normal pages, and light SPAs are very achievable on 512 MB with this profile. A single
**heavy** SPA (WhatsApp/Teams/Gmail full, ~300 MB+ resident) may still OOM regardless — that's a
hardware limit, not a tuning gap. The stripped Phase-3 engine widens the margin but won't erase it.
