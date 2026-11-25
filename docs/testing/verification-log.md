# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-11-26 — Wave 3B: automation matrix (#17b), per-wallpaper quality & VRAM diagnostics (#21), storage health (#22), .wmpack & per-display lock screen playlists (#23)

- build.py --renderer-only: OK (rebuilt C++/Rust renderer and regenerated App/Bridge/Generated bindings)
- check_rust.py: PASS (core 436, bridge 999, core-integration 20, shader 1090; 0 failed; 5 desktop window opt-in tests excluded)
- check_renderer.py: PASS (C++ Metal tests incl. metal_vram_gauges_test, 12/12 generated GPU parity pixels_equal=True diagnostics=0, 8x2 reload cycles: 0; 7 opt-in local-asset/corpus tests skipped)
- test.py: PASS (36/36 Python suites / 731 tests; 5392 passed, 0 failed, 70 skipped of 5462 native tests in 171s)
- verifier-w3b: PASS after fixing Rust restart persistence, stacked-Spaces SpacePosters protection, parked-Space render_scale reset, lower-quality floor, .wmpack autoApplyOnConnect guard, and lock-screen rotation cancellation
- Gaps: Release .app not rebuilt (unrequested); opt-in UI/desktop/local-corpus/WE-VM visual checks not run; 3 pre-existing XCTest main-thread runtime warnings in signature/keychain tests

## 2026-11-25 — Wave 3A Parallax power fix, Automation/Intents, Smart Playlists, and Media Widgets (#24, #17a, #20, #19, #18)

- Scope: Parallax static subgraph cache & on-demand easing convergence (#24), display-topology auto-layout (#17a), query/action App Intents + status.json + extended hotkeys + Presentation Mode (#20), wallpaper metadata + Smart Playlists + skip-recent + weighted shuffle + Sleep Timer (#19), Now Playing & Image Sticker widgets + per-wallpaper/Space scope (#18).
- python3 scripts/build.py --renderer-only -> PASS (0 diff in App/Bridge/Generated/).
- python3 scripts/check_renderer.py -> PASS (all C++ tests incl. 9 new parallax/on-demand/timer/NodeBinding tests + 12 generated GPU parity checks pixels_equal=True, diagnostics=0, reload cycles 0; 7 opt-in local asset/corpus tests skipped).
- python3 scripts/check_rust.py -> PASS (core 436, bridge 992, core-integration 20, shader 1094; 0 failed; opt-in desktop/media/network disabled).
- python3 scripts/test.py -> PASS (36/36 Python suites OK; 5343 passed, 0 failed, 70 skipped of 5413 native tests in 175s).
- Localization & review: App/Resources/Localizable.xcstrings edited as text (+131 net keys across en/ja/ko/pt-BR/zh-Hans/zh-Hant); verifier-w3a PASS after resolving 3 blockers (sticker test/undo isolation, sleep timer pause cancel, Presentation Mode async re-entrancy).
- Not run: Release .app build (not requested), desktop UI tests (--ui), live Steam/media opt-ins, and live macOS visual/energy inspection of parallax reuse, Now Playing widget, and display hotplug.

## 2026-11-25 — Wave 2B Settings, Widgets Undo, and Browse/Downloads upgrades (#12-#15)

- Scope: Settings unified thumbnail chooser, Automation enable/reorder/solar readout, merged Scale (>1.0 preserved), async Storage metrics, Search section titles/live units/scoping (#12); Desktop Widgets scoped Undo/Redo, gesture coalescing, safe canvas Delete, .sun Displays link (#13); Workshop Collection/Favorites Download missing, lazy tile context menus, Pixiv multi-page strip & batch save, Downloads batch controls & Pixiv Download next, async disk space, Steam web persona identity, Workshop update dismiss, LibraryFolderRow Storage jump (#14-#15).
- python3 scripts/test.py: PASS (36/36 Python suites OK; 5296 passed, 0 failed, 70 skipped of 5366 native tests in 137s).
- Localization: App/Resources/Localizable.xcstrings edited as text (+38 new keys across en, ja, ko, pt-BR, zh-Hans, zh-Hant; -1 superseded unreferenced key); catalog and panel localization suites passed.
- Code review: verifier-w2b re-verified all fixes and signed off PASS (no blockers).
- Not run: Release build (not requested), opt-in --ui desktop tests, and live visual inspection.

## 2026-11-25 — Wave 2A UI/UX workflow upgrades (#8, #9, #10, #11, #16)

- Scope: three-page clickable tags, ActiveFilterChipsBar, Workshop Hide installed (#8); Collections scope menu, quick actions, target display wallpaper titles, inline playlist controls (#9); Inspector search/modified/collapsible headings, artwork Preview, Preview shortcuts/Apply (#10); Menu Bar dynamic scroll/compact picker/Mute All/playlist badge/reveal (#11); Shift+Arrow, Cmd+S, Placement pinch/Option+scroll/double-click/center guides, Preset Update & Apply & Save (#16).
- Routine gate: python3 scripts/test.py — PASS (36/36 Python suites OK; 5251 passed, 0 failed, 70 skipped of 5321 native tests in 161s).
- Localization: App/Resources/Localizable.xcstrings +37/-1 keys across all 6 shipped languages (en, ja, ko, pt-BR, zh-Hans, zh-Hant), verified by test_localization_catalogs.py and test_panel_localization.py.
- Review: verifier-w2a read-only review PASS (0 blockers after fixing 3 must-fix and 3 nit findings with added unit tests).
- Not run: Release build (not requested), --ui desktop tests, and live visual inspection.

## 2026-11-25 — Wave 1 P0 fixes and quick wins (#1-#7)

- Scope: NowPlaying theme/day-night, empty Favorites/narrowingFilterCount/collectionID, a11y/focus/cursor/SelectButton, thermal hysteresis/battery renderScale/Web middle-click+language, Workshop updates/comments/UpdateWindow, Widgets multi-display preview+Copy Style+Cmd-D, Switch Transitions, Lock Screen renderScale.
- python3 scripts/build.py --renderer-only -> PASS (0 diff in App/Bridge/Generated/).
- python3 scripts/check_rust.py -> PASS (core 436, bridge 992, core-integration 20, shader 1094; 0 failed; opt-in desktop/media/network disabled).
- python3 scripts/check_renderer.py -> PASS (pixels_equal=True, diagnostics=0, reload cycles 0; 7 opt-in local asset/corpus tests skipped).
- python3 scripts/test.py -> PASS (36/36 Python suites OK; 5207 passed, 0 failed, 70 skipped of 5277 native tests in 162s).
- Localization: App/Resources/Localizable.xcstrings edited as text (+22 keys across en/ja/ko/pt-BR/zh-Hans/zh-Hant, -2 superseded keys); test_localization_catalogs and test_panel_localization passed.
- Not run: Release .app build (not requested), desktop UI tests (--ui), live Steam network/media opt-ins, and live macOS visual inspection of Halloween Light popover/multi-display widgets/switch transitions.

## 2026-11-25 — Lock-screen and screen-saver live media integration and audio response (#258)

Forwarded Now Playing media state and 224-band system-audio spectra from the main app to the sandboxed lock-screen/screen-saver extension for Scene and Web wallpapers while keeping previews, unlocked desktop settle surfaces and plain videos excluded.

- `python3 scripts/build.py --renderer-only` — exit 0; rebuilt workspace and regenerated `App/Bridge/Generated/`
- `python3 scripts/check_rust.py` — exit 0; core 436 passed (5 desktop-window excluded), bridge 992 passed, core-integration 20 passed, shader all suites passed, 0 failed; desktop/media/network opt-ins disabled
- `python3 scripts/check_renderer.py` — exit 0; all C++/Metal suites passed (audio_tests 80/80, SpectrumExport128Test 11/11), 12/12 generated scenes pixels_equal=True, reload cycles 0; 7 local-corpus asset checks skipped
- `python3 scripts/test.py` — exit 0; 36/36 Python suites OK, Swift unit/integration 5172 passed, 0 failed, 70 skipped of 5242 (including LockScreenLiveFeedTests 6/6 and ScreenSaverWebSurfaceTests 17/17)
- Unverified offscreen: live macOS 26+ lock-screen/screen-saver presentation, real MediaRemote/AppleScript players and live CoreAudio tap across lock/unlock/display sleep require an authorized manual check; Release app was not rebuilt

## 2026-11-24 — Ignore WallpaperAgent LastUse updates and isolate lock-screen transient retries (#259)

Fix for #259: SystemWallpaperStore ignores WallpaperAgent LastUse timestamp advances when confirming or replaying Desktop/Idle/Linked choices, and LockScreenWallpaperService resets transient failure budgets on new targets while keeping unrelated refreshes from bypassing back-off.

- Red before fix (python3 scripts/test.py --only SystemWallpaperStoreTests --only LockScreenWallpaperServiceTests/...): 4 new regression tests failed (26 passed, 4 failed of 30) reproducing both LastUse reload conflicts and burned/shared retry budgets.
- Targeted after fix (SystemWallpaperStoreTests, LockScreenWallpaperServiceTests, LockScreenWallpaperTests): 208 passed, 0 failed, 0 skipped.
- Full gate (python3 scripts/test.py, macOS 27.3): all 36 Python test modules passed; native 5,165 passed, 0 failed, 70 skipped of 5,235 (1 runtime warning).
- Not verified: live WallpaperAgent reload on the desktop, visual lock-screen check, or Release app build.

## 2026-11-23 — Workshop queue pauses after Steam limits sign-ins (#256)

Fix for #256: a rate-limited sign-in (SteamCMD .rateLimited, QR logOnRefused(84)) pauses the jobs still waiting instead of each spending another sign-in. Verified on a fork's Test workflow (hosted macOS 26) because the contributor's machine has no Xcode.

- Test workflow, --only the two new tests, tests-only commit 76246585 — both failed as expected: SteamCMD launched ["1","2","3"] instead of ["1"]; QR path opened 2 logons instead of 1
- Test workflow, full, fix commit 3790b0bb — native: 5153 passed, 2 failed, 74 skipped of 5229; both new tests pass
- The 2 native failures are pre-existing on hosted runners, not this change: DesktopWidgetTests/testADateCanBeWrittenInAnotherCalendarInThatCalendarsOwnWords (九月30 vs 九月三十) and WebWallpaperErrorStackTests/testStacksReadAsV8WritesThem; upstream Test run 43986617796 (2026-11-17) failed both the same way
- Test workflow rust job — passed; renderer job — blocked: check_renderer.py's cmake build of the test targets timed out after 600 s on the fork's cold cache (no renderer or bridge change here)
- `python3 scripts/test.py --python-only` (Python 3.13, local) — exit 0, 36 script test files OK
- Not verified: a real Steam rate limit (scripted SteamCMD and fake Steam only), no desktop/UI run, nothing checked visually

## 2026-11-23 — Scale percentage slider for a display (#248)

A slider from 10% to 100% that sets a display's scale factor, in the inspector's display card and in Settings › Displays.

- `python3 scripts/test.py` (Python 3.15) — exit 0; 36 Python modules passed; native 5223 tests: 5153 passed, 70 skipped, 0 failed. Run with the energy-ratings refresh fix applied, which ships as its own change.
- The same gate without that fix — 5152 passed, 1 failed: `PanelLibraryRowsTests/testRefreshEnergyRatingsRebuildsAndNotifiesOnlyWhenRatingsMoved`, which fails the same way on `main` at `2f7cd127` without this change.
- `python3 scripts/test.py --only InspectorInputTests --only InspectorRenderTests/testADisplayCardsScaleSliderSendsTheScaleFactorOfThePercentageItSettlesOn` — 7 passed.
- Not checked: the slider on a real display (no desktop run was requested), the row's layout by eye in the five languages, and the Settings › Displays slider, which no automated test drives. No Release build.

## 2026-11-21 — Installed library sort by Energy use (#251)

- `python3 scripts/test.py --python-only` — exit 0; all 36 Python modules passed (including `test_panel_localization.py`, `test_localization_catalogs.py`, `test_doc_links.py`).
- `xcodebuild -project WallpaperMachine.xcodeproj -scheme WallpaperMachine -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build-for-testing` — exit 0 (`TEST BUILD SUCCEEDED`, zero warnings in touched files).
- `python3 scripts/test.py --only LibrarySortTests --only InstalledBrowserModelTests --only PanelLibraryRowsTests --only PanelViewStateTests --only InstalledPageRenderTests` — blocked (exit 70): `xcodebuild` failed in this sandbox with `Failed to prevent system sleep during UI testing. Error code: -536870211` (`IOPMAssertionCreateWithName`).
- Native XCTest execution and live UI visual verification of the Energy use sort menu remain to be run outside the sandbox; the Release app was not rebuilt.
