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

## 2026-11-26 — Signed Sparkle software updates

- python3 scripts/test.py: all Python modules passed; 5,408 native tests passed, 0 failed, 70 skipped. The first run hit Git maintenance during temporary repository cleanup; the passing run disabled automatic Git maintenance for the test process only.
- An isolated Sparkle 2.10 host with disposable Ed25519 keys discovered the signed update without fetching the archive, retried a 502 once at the alternate endpoint, and rejected a modified feed without a retry.
- Focused Release tooling checks include signed appcast/ZIP verification and rejecting tampering; the legacy DMG manifest still resolves from both GitHub repository names. Debug packaging preflight passed with existing local Homebrew macOS-floor and crc-catalog notice warnings.
- Companion website: nine Worker route tests, typecheck and build passed. No desktop installation/restart, Release build, notarization, deployment or publication. Configure the dedicated Actions signing key pair and deploy the update routes before shipping.

## 2026-11-26 — Lock screen and screen saver keep interactive scene layer choices (#262)

- Two independent, offscreen Native Metal renderers loaded Workshop 3632513108 with null audio. Clicking its character switch showed Female Rover on the desktop; a fresh renderer showed Male Rover. Importing the 55-byte layer reply showed Female Rover without replaying the click.
- The existing Wallpaper Engine 2.8.0.42 default frames at 30.06/45.86 seconds were compared with scripts/we_reference.py before and after. Mean absolute difference: 18.09 → 18.09 and 19.03 → 19.04; pixels off by >48: 15.93% and 17.49%, unchanged. Those captures contain no click and do not verify a lock transition.
- python3 scripts/test.py: 731 Python tests; 5,489 native tests passed, 70 skipped, none failed. The focused lock-screen, handoff and authority selection passed 35/35.
- python3 scripts/check_rust.py: core, bridge, integrations and shader suites exited 0. Five real-window cases were excluded; desktop/media/network opt-ins stayed off.
- python3 scripts/build.py --renderer-only rebuilt the archive and bindings. The six interactive-layer tests cover delayed writes, switch-back, release of omitted values, and invalid input. A detached CAMetalLayer separately verified the native notification and restore while paused.
- The first check_renderer.py --project run exposed a crash in the diagnostic PPM writer: mono glyph atlases have one byte per pixel, not four. After rebuilding the probe, WE_TEST_RANDOM_SEED=1 python3 scripts/check_renderer.py --skip-build --project <project.json> exited 0. All 12 generated scenes and the reported project matched between pooled and isolated rendering; the project still logs a pre-existing malformed particle bounds value. Optional corpus, local video and energy checks were skipped.
- No desktop interaction, real macOS lock/saver transition, install or Release app build. Windows reference shots were reused, not recaptured.

## 2026-11-26 — Wave 4B: Pixiv deep browsing phase B (#28a) and cross-Mac manual sync folder (#28b)

- test.py: PASS (36/36 Python suites / 731 tests; 5477 passed, 0 failed, 70 skipped of 5547 native tests in 210s)
- verifier-w4b: PASS after fixing Pixiv translation cancellation/generation guards, Author Refresh actor cache ordering, PixivBrowseState mid-load scope/sign-in state, pre-parse JSON node cap, off-main-actor bookmark resolution, and multi-display widget merge
- Localization: 110 new keys inserted surgically as text into App/Resources/Localizable.xcstrings across all 6 shipped languages; Extension/Localizable.xcstrings untouched
- Scope: pure Swift/UI/tests/docs (no Rust/C++ renderer changes); Release .app not rebuilt (unrequested); opt-in --ui/desktop/live-Pixiv/iCloud-Drive checks not run

## 2026-11-26 — Wave 4A: MP4 HDR mdcv/clli & >2ch AAC/Vorbis downmix (#25a/#25c), video A-B trim (#25b), multi-display span phase 1 (#27), WebAudio GainNode & safe usershortcut (#26a/#26c), audio-response FFT tuning & per-app capture (#26b)

- build.py --renderer-only: OK (C++ Media/Sound/Engine + Rust Core/Bridge rebuilt, App/Bridge/Generated regenerated)
- check_rust.py: PASS (core 446, bridge 1003, core-integration 20, shader 1089; 0 failed; 5 desktop window opt-in tests excluded)
- check_renderer.py: PASS (all C++ regression suites incl. isobmff/matroska/webm/audio_tests 86/86/scenescript_media_event_smoke, 12/12 GPU parity pixels_equal=True diagnostics=0, 8x2 reload cycles: 0; 7 opt-in local-asset skips)
- test.py: PASS (36/36 Python suites / 731 tests; 5453 passed, 0 failed, 70 skipped of 5523 native tests in 165s)
- verifier-w4a: PASS (19/19 [MUST-FIX] blockers fixed & re-verified: cross-wallpaper usershortcut isolation, non-blocking Shortcuts runner, WebAudio iframe/seed sync, WebM trimmed audio/DTS/live seek, still-span/Web host sequencing & posters, zero-I/O AudioResponse UI, CoreAudio rollback & helper matching)
- Gaps: Release .app not rebuilt (unrequested); opt-in --ui/desktop/live-Steam/local-corpus/WE-VM visual checks not run; Wave 4B (#27 Scene compat w/ WE VM, #28 Pixiv B & manual sync folder) remains queued

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
