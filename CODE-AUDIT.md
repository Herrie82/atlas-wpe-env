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

## GROUP A — Safe deletions — partly DONE 2026-07-07 (A1 all; A2-4 done; A2-5 KEEP; A2-6 deferred; A2-7 skipped)

### A1 · atlas-wpe-backend — ✅ ALL DONE (commit `7298dee`, compile-checked)
- [x] **Deleted `atlas-wpe-glue.cpp`** — stale sketch, old 4-arg `wpe_atlas_view_backend_create`, not built.
- [x] **Removed `m_fsFillH`** (`BrowserPageWPE.h`) — Tier-1 vestige, zero refs.
- [x] **Removed `m_bufferLock` + `m_bufferLockName`** (decls + ctor-init + dtor `free(0)`) + the now-unused
  `#include <semaphore.h>`. (Build re-injects semaphore.h into the merged header, so no build impact.)

### A2 · atlas-browser-app (enyo)
- [x] **Deleted the 9 tracked backup files** (commit `c88fc29`): `*.orig` ×6, `*.prehttps` ×2, `*.preprivate`.
- [x] **Icons — KEPT (decision: keep all).** NOTE/correction: `appinfo.json` references **two** — `icon.png`
  (icon) **and** `icon-256x256.png` (splashicon) → both load-bearing. `icon-64x64.png` is a byte-identical dup
  of `icon.png`; `icon-48x48.png`, `icon-1024x1024.png`, `icon-1024x1024.psd`, `icon-256x256.psd` are
  unreferenced (~6.1 MB) but **left in place per decision**. (Removable later if desired.)
- [~] **Dead functions — MARKED, NOT DELETED (revisit later).** `Browser.js doneSelectionClick`,
  `Browser.js deleteImages`, `ReaderView.js _readerSpinner`, `URLSearch.js highlightResultText` each annotated
  `// UNUSED/TODO(audit A2-6): … revisit in detail before deleting.` (commit `c88fc29`). No caller/handler
  wiring found, but kept pending a detailed review.
- [ ] **`.gitignore` — NOT actioned** (not requested). Two malformed lines remain: `resources/` has a trailing
  CR, and `.DS_Storeearth_icons_final(8)/` merges two entries (missing newline). Fix if/when desired.

---

## GROUP B — Retire superseded / decide — decided 2026-07-07 (B3a done; B1/B2/B3b KEPT)

### B1 · Tier-2 fullscreen (superseded by mediad handoff) — atlas-wpe-backend — ⏸ KEEP FOR NOW
DECISION: **keep** until the mediad handoff display + reliability are fully signed off. Not deleted.
Still present (triple-gated, self-described "frozen fullscreen", effectively a no-op fallback):
- `enterFsResize()` / `exitFsResize()` (`.cpp:1250-1291`) + decls (`.h:67-68`); the enter-fullscreen else-branch
  (`.cpp:628-641`) and leave-fullscreen else (`.cpp:647`).
- members `m_fsActive`, `m_fsRestoreH`, `m_fsRestoreScrollY` (`.h:294-296`). (`m_fsPending` is live — mediad uses it.)
- stale Tier-1/Tier-2 comments (`.cpp:607-611, 628-631`).
→ Revisit for deletion once mediad is confirmed the sole fullscreen path.

### B2 · enyo commented-out blocks — ⏸ KEEP (feature markers)
DECISION: **keep** — they mark disabled/not-yet-wired features. Not deleted.
- `Preferences.js:57-64` Autofill RowGroup; `CertificateDetail.js:171,178,210,217` setValue/warn;
  `BrowserApp.js:210-211,281` showAppMenu/resize/hasKind; `Browser.js:191,198,912` findBar/findInPage/setZoom;
  `ActionBar.js:82,90` bookmarks.

### B3 · BrowserAdapter
- [x] **B3a DONE** — removed the dead `DRAW_DEBUG_COLORS` block: `drawDebugBorder`/`drawDebugFill` (both the
  `#if` impls and the `#else __attribute__((unused))` stubs, no call sites) **plus** the 4 orphaned debug
  `QColor` statics (`colorNoOffscreen`/`colorNoConnection`/`colorOffscreenSurfEmpty`/`colorGenericBorder`,
  declared-only). Commit in BrowserAdapter repo; 0 leftover refs.
- [keep] **B3b KEPT** — `js_dragStart`/`js_dragProcess`/`js_dragEnd` (`.cpp:3341-3389` + table rows `.cpp:397-399`).
  The enyo app currently uses only `setDragMode`, but these are **intentionally kept** — pending open scroll/drag
  issues where they may be needed. (Verified: `js_setDragMode` is live and stays regardless.)

---

## GROUP C — Real fixes (bugs / inconsistencies, RISK: low) — ✅ DONE 2026-07-07

- [x] **ATLAS_DESKTOP rename bug** — `Settings.cpp:50` uses `#ifdef ATLAS_DESKTOP` (renamed from
  `ISIS_DESKTOP` in commit `456bf53`) but `BrowserServer/Src/Makefile.Ubuntu:55` still passed
  `-DISIS_DESKTOP`. **FIXED (a):** Makefile.Ubuntu now passes `-DATLAS_DESKTOP`. (Committed, BrowserServer repo.)
- [x] **`launchbs-252.sh:10`** — stale hardcoded `/media/internal/wpe-238/fonts.conf`. **FIXED (a):** dead
  fallback line deleted. (Committed, env repo.)
- [x] **Stale comment** — `BrowserPageWPE.cpp:2270` `mouseEvent` "once setScrollPosition is wired". **FIXED
  (b):** reworded — `contentX/Y` go straight to `dispatchPointer` (correct only unscrolled/unzoomed); scroll
  tracking IS wired now; the content→view map remains a real TODO for scrolled/zoomed taps. (Committed, backend.)
- [x] **`deploy-252.sh` tail** — writes a `run.sh` that execs `frame-dump`, not `BrowserServer-atlas`.
  **FIXED (a):** header relabeled as the standalone frame-dump repro-harness deployer. (Committed, env repo.)
- [x] **`upstart-atlas`** ran `./BrowserServer -platform qbs`. **Investigated + FIXED (a+b):** boot chain =
  upstart → `deviceroot/atlas/BrowserServer` (the `wrapper-BrowserServer` script) → `exec .../wpe-252/
  BrowserServer-atlas -platform Minimal`, so the `qbs` arg was ignored. (b) dropped `-platform qbs` from
  `upstart-atlas`; (a) re-synced the device wrapper's drifted log target (`>>bs-crash.log` append →
  `>bs-atlas.log` truncate; only line 41 differed). Both deployed to device (/ remounted rw then re-sealed ro).
  (Committed, env repo.)

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
