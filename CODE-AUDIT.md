# Atlas Browser — Code Audit (dead code / cruft / TODO / no-op)

Date: 2026-07-07. Scope: **our** Atlas-specific code across the repos we own/modify.
Method: 3 parallel read-only audits (backend, env/tooling, BrowserServer+Adapter+app), each verifying
call sites / git-diff-vs-upstream. Upstream Palm/WPE code was excluded.

Repos covered:
- `atlas-wpe-backend/` — BrowserPageWPE.{cpp,h}, wpe-atlas-backend.{c,h}, atlas-wpe-glue.cpp
- `atlas-wpe-env/` — build/deploy scripts, WebKit patch, roles, ipk pull files
- `doctor305/BrowserServer/Src/` — our ATLAS_LUNA/mediad + other changes (vs base `e2506f5`)
- `GitHub/BrowserAdapter/` — our LunaCE/Atlas changes (vs base `84a330a`)
- `GitHub/atlas-browser-app/` — the enyo JS app (entirely ours)

Status legend: `[ ]` todo · `[x]` done · **RISK**: none / low / medium.

---

## ⚠️ CORRECTION — do NOT delete these (audit false-positive)

The BrowserServer audit ran only against that repo's own Makefiles and concluded the **`ATLAS_LUNA` +
mediad-handle block is never compiled / dead, targeting an unwritten `mediadBegin`**. **That is wrong.**
- The device build uses `atlas-wpe-env/build-browserserver.sh`, whose `DEF` includes `-DUSE_LUNA_SERVICE
  -DATLAS_LUNA` → the block **is** compiled.
- `mediadBegin` **is** defined — in `atlas-wpe-backend/BrowserPageWPE.cpp`, merged into `src/BrowserPage.cpp`
  as `BrowserPage::mediadBegin` by the build's Python merge step.
- This is the **live, working mediad fullscreen-video handoff**. Keep all of:
  `BrowserServer.h` getMediaHandle()/m_mediaService, `BrowserServer.cpp` ATLAS_LUNA startService branch,
  and the `#if defined(USE_LUNA_SERVICE) && !defined(ATLAS_LUNA)` guard.

---

## GROUP A — Safe deletions (verified dead, RISK: none)

Do these first; each is provably unused.

### A1 · atlas-wpe-backend
- [ ] **Delete `atlas-wpe-glue.cpp`** (entire 117-line file). Stale "SKETCH"; declares a parallel mini
  `BrowserPageWPE` with obsolete signatures and calls the **old 4-arg** `wpe_atlas_view_backend_create`
  (header now requires the **6-arg** form, `wpe-atlas-backend.h:47`) → would not compile. Superseded by the
  real `BrowserPageWPE.cpp`. Not in the build path.
- [ ] **Remove member `m_fsFillH`** (`BrowserPageWPE.h:296`) — zero references anywhere. Vestige of the
  removed Tier-1 fullscreen CSS path.
- [ ] **Remove `m_bufferLock` (sem_t\*) + `m_bufferLockName`** (`BrowserPageWPE.h:290-291`). Copied from the
  QtWebKit `BrowserPage`; `m_bufferLock` is only init to 0 (ctor `.cpp:132`), never read/written/freed;
  `m_bufferLockName` only init to 0 + `free(0)` in dtor (`.cpp:166`). Delete both + their ctor/dtor lines.

### A2 · atlas-browser-app (enyo)
- [ ] **Delete tracked backup files** (9): `source/Browser.js.orig`, `source/BrowserApp.js.orig`,
  `source/BrowserApp.js.prehttps`, `source/BrowserApp.js.preprivate`, `source/BrowserContextMenu.js.orig`,
  `source/URLSearch.js.orig`, `source/URLSearch.js.prehttps`, `css/browser.css.orig`, `depends.js.orig`.
- [ ] **Delete unused/duplicate icons**: `icon-64x64.png` (byte-identical to `icon.png`, which `appinfo.json`
  uses); `icon-48x48.png` + `icon-1024x1024.png` (present but not referenced by appinfo.json);
  `icon-1024x1024.psd` (~5 MB) + `icon-256x256.psd` (~360 KB) source art (move to an art folder outside the
  app, or drop).
- [ ] **Remove dead functions** (defined once, nothing wired to them): `Browser.js:765 doneSelectionClick`,
  `Browser.js:998 deleteImages`, `ReaderView.js:86 _readerSpinner`, `URLSearch.js:259 highlightResultText`.
- [ ] Fix malformed `.gitignore` merged entry `.DS_Storeearth_icons_final(8)/` (missing newline).

---

## GROUP B — Retire superseded / decide (RISK: low–medium, needs a call)

### B1 · Tier-2 fullscreen (superseded by mediad handoff) — atlas-wpe-backend
The pre-mediad fullscreen attempts. Reachability is **triple-gated** and self-documented as non-working:
`enter-fullscreen` only fires if `/tmp/atlas_fs` (default OFF, `.cpp:578`); then if `/tmp/atlas_mediad` set →
new path, else → `enterFsResize()`, which **immediately returns** unless `/tmp/atlas_fsresize` exists
(`.cpp:1263`) and its own header (`.cpp:1255-1262`) says it produces "frozen fullscreen" (frames dropped).
- [ ] Delete `enterFsResize()` / `exitFsResize()` (`.cpp:1253-1292`) + declarations.
- [ ] Delete members `m_fsActive`, `m_fsRestoreH`, `m_fsRestoreScrollY` (Tier-2 only). **Keep `m_fsPending`**
  — it is reused by the live mediad enter path (`.cpp:621-647`).
- [ ] Remove stale Tier-1/Tier-2 explanatory comments (`.cpp:607-613`).
- **DECISION**: delete now, or keep one more cycle as a (broken) fallback until mediad display + reliability
  are fully signed off? Recommendation: delete — it is not a working fallback.

### B2 · enyo commented-out blocks (decide keep vs remove)
- `Preferences.js:57-64` — Autofill RowGroup + "Clear Autofill Information" button, block-commented.
- `CertificateDetail.js:171,178` commented `setValue`; `:210,217` commented `this.warn`.
- `BrowserApp.js:210-211` `//showAppMenu()/resize()`; `:281` `//browser.hasKind()`.
- `Browser.js:191,198,911` commented findBar/findInPage/setZoom; `ActionBar.js:82,90` commented bookmarks.

### B3 · BrowserAdapter (mostly clean)
- `BrowserAdapter.cpp:974,978` — `drawDebugBorder`/`drawDebugFill` are now orphaned empty
  `__attribute__((unused))` stubs (our handlePaint rewrite removed the call sites). Remove or keep as stubs.
- `BrowserAdapter.cpp:3341-3389` — `js_dragStart`/`js_dragProcess`/`js_dragEnd` duplicate the drag pathway
  that `js_setDragMode` + pen-gesture handlers already funnel into `asyncCmdDragStart/Process/End`. **Confirm
  the app still needs both exposed APIs** before removing.

---

## GROUP C — Real fixes (bugs / inconsistencies, RISK: low)

- [ ] **ATLAS_DESKTOP rename bug** — `Settings.cpp:50` uses `#ifdef ATLAS_DESKTOP` (renamed from
  `ISIS_DESKTOP` in commit `456bf53`) but `BrowserServer/Src/Makefile.Ubuntu:55` still passes
  `-DISIS_DESKTOP`. Nothing defines `ATLAS_DESKTOP` → the desktop config block (`~/.atlas` paths) is silently
  dead in that build. Fix the Makefile flag (or drop the desktop build if unused). Only matters if the
  Ubuntu/host build is still used; the device build (`build-browserserver.sh`) is unaffected.
- [ ] **`launchbs-252.sh:10`** — stale hardcoded `/media/internal/wpe-238/fonts.conf` (old wpe-238 layout;
  everything else moved to the cryptofs `wpe-252` deviceroot). Also the script is broadly superseded by
  `ipk-build/pull/wrapper-BrowserServer` (the shipped boot wrapper), which sets the full GStreamer/JIT/RAM
  env launchbs lacks. Update the path or retire the script.
- [ ] **Stale comment** — `BrowserPageWPE.cpp:2270` `mouseEvent` TODO "map content→view coords … once
  setScrollPosition is wired" — scroll **is** wired now; the comment is outdated.
- [ ] **`deploy-252.sh` tail** (`:48,79-88`) — writes an `OUT/run.sh` that execs `frame-dump`, not
  `BrowserServer-atlas`; vestigial standalone-harness era. The real runtime is BS via wrapper + ipk-postinst.
  Trim or clearly label as the frame-dump repro harness only.
- [ ] **`upstart-atlas`** runs `./BrowserServer -platform qbs` while the wrapper actually execs
  `BrowserServer-atlas -platform Minimal` (arg ignored) — vestigial `qbs` arg, harmless.

---

## GROUP D — Low priority / keep

### D1 · Write-only members (remove or wire up) — atlas-wpe-backend
- `m_userAgent` (`.h:337`) — stored by `setUserAgent` (`.cpp:2630`), never read (UA forced in `ensureWebView`).
- `m_frozen` (`.h:325`) — set in freeze/thaw (`.cpp:2608/2616`), never read.
- `m_focused` (`.h:324`) — set in setFocus (`.cpp:2601`), never read.

### D2 · Known WIP / tech debt — KEEP (tracked, not cruft)
- **de-QtWebKit cleanup** not done: `link-bs-252.sh:23` `-lQtCore/-lQtGui/-lQtNetwork`;
  `build-browserserver.sh` QtWebKit-only compile hacks (`-Demit=`, `-DQT_NO_KEYWORDS`, `-fpermissive`,
  `EXCLUDE` list); `BrowserPageWPE.h:20` `#include <QtWebKit/QtWebKit>` "link TBD". Pulls Qt just for interface
  types (`QWebHitTestResult`, `QString`).
- **`/var/atlas252` prefix bridge** — from `build-webkit-252.sh:16-22` CMAKE_INSTALL_PREFIX workaround;
  carried by `ipk-postinst.sh:24`, `deploy-252.sh`, `redeploy-webkit.sh`. Documented "PROPER FIX" = rebuild
  WebKit with DESTDIR / device prefix baked in.
- **TODO stubs (intentional)**: `clearHistory()` empty (`.cpp:1198`, no WPE API); `setVirtualWindowSize`
  viewport-width TODO (`.cpp:1534`); the long-tail `QBsClient` command stubs in `BrowserPageWPE.h` (match the
  command surface — not removable).

### D3 · Debug scaffolding — KEEP (behind toggles or intentional)
- Gated by `BPWPE_DEBUG`: `WLOG`/`ATLAS_LOG` file logging, `BPWPE_DUMPFRAME`, backend PERF/VSTAT/STRIP/VRECT/
  LOCKSURF counters.
- File-trigger test hooks (700 ms `scrolltest_poll`, cheap `access()` probes): `/tmp/atlas_scrolltest`,
  `/tmp/atlas_rotatetest`, `/tmp/atlas_fstest`, `/tmp/atlas_mediadgo`; `SIGUSR1` scroll test.
- mediad diagnostic toggles: `/tmp/atlas_mediad`, `_appid`, `_loadonly`, `_shrink`, `/tmp/atlas_vbounds`.
- Always-on by design: crash-handler backtrace→`/tmp/bpwpe.log` (`__attribute__((constructor))`),
  `MLOG`→syslog (mediad trace, visible without BPWPE_DEBUG), per-page Navigation-Timing eval
  (`perfTimingTimeout`, log output still gated).

### D4 · Noise
- 5 env files show as git-"modified" but the diff is **only file-mode 644→755** (chmod), zero content — commit
  or ignore. Files: `build-webkit-252.sh`, `deploy-252.sh`, `ipk-build/pull/wrapper-BrowserServer`,
  `launchbs-252.sh`, `link-bs-252.sh`.

---

## Coherent / current (audited, nothing to do)
- `wpe-2.52.4-atlas-fullscreen-fixes.patch` — 3 self-consistent WPE 2.52.4 crash fixes (nextTarget guard,
  hostFD.duplicate, WebFullScreenManagerProxy CheckedPtr→WeakPtr), instrumentation already stripped.
- `roles/org.webosports.browserserver.json`, `ipk-build/pull/{upstart-atlas,wrapper-BrowserServer}` — current.
- BrowserAdapter diff is essentially clean (our handlePaint rewrite even deleted old upstream dead blocks; all
  added `TRACEF` are release-gated).
- No genuinely-uncalled functions in the backend beyond `atlas-wpe-glue.cpp` (long-tail stubs are intentional).
- enyo app: no `console.log` anywhere; ~30 `this.log()` traces remain (borderline — keep-or-not).

---

## Suggested execution order
1. **Group A** — safe deletions, one commit per repo (backend / env / app). RISK none.
2. **Group C** — small fixes (ATLAS_DESKTOP flag, launchbs path, stale comment). RISK low.
3. **Group B** — after deciding: retire Tier-2 fullscreen (recommended once mediad is signed off), prune enyo
   commented blocks, resolve the BrowserAdapter dup drag API.
4. **Group D1** — optional member cleanup. D2/D3/D4 = keep.
