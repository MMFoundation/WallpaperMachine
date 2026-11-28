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

## 2026-11-28 — Update handover and lock-screen poster recovery

- Focused native suite: DesktopWallpaperTests, LockScreenWallpaperTests, QuitReasonTests, QuitSupervisorTests, QuitRequestAnswerTests and PixivDeepBrowsingTests: 274 passed.
- Final `python3 scripts/test.py` on Apple silicon, macOS 27.0.1 and Xcode 27.2: 37 Python modules passed; 5,444 native tests passed, 70 skipped, no failures. XCTest reported one runtime warning.
- Regression coverage includes archive replay with poster writing off, already-pruned records, same-size atomic journal replacement, damaged baselines, bounded poster writes and installer requests during an existing quit.
- Not exercised: a real Sparkle install, live desktop/lock-screen handback, or the opt-in asset and network cases. No Release app was built.

## 2026-11-27 — Christmas seasonal look and Liquid Glass window appearance (#267)

- Command: python3 scripts/brand.py --seasonal
- Result: regenerated AppIconHalloween.imageset/halloween.png and AppIconChristmas.imageset/christmas.png
- Command: python3 scripts/test.py
- Result: all 37 Python test modules (748 tests, including brand, design tokens, localization catalogs, doc links) passed; XcodeGen regenerated project; native suite 5434 passed, 0 failed, 70 skipped of 5504 in 167s
- Coverage added: AppThemeTests (Christmas dates, mutual exclusivity, Liquid Glass preview/commit/validation), AppIconImageTests, SurfacePaletteTests (Christmas WCAG contrast & miniatures), PanelThemeTests (Liquid Glass opacity curve & window style), AppearanceSettingsTests, LibraryTileRulesTests, ShellRenderTests, SettingsSectionsLocalizationTests, WallpaperBackupTests, test_brand.py
- Not run: Release build (not requested) and live desktop visual check of Liquid Glass translucency, Reduce Transparency toggle, and Christmas Dock icon/horizon on screen

## 2026-11-27 — Fill with blurred backdrop (#268)

- Added WallpaperScalingMode::FILL_BLURRED (5, fill_blurred, FillBlurred) across C++ Metal renderer, Rust core/bridge, Swift bindings, native video/lock-screen/preview layout, inspector, Settings > Displays, localization and docs.
- python3 scripts/build.py --renderer-only -> OK (cargo release build + uniffi-bindgen Swift bindings regenerated).
- python3 scripts/check_rust.py -> OK (core 447 passed, 5 desktop_window excluded; bridge 1004 passed; core-integration 20 passed; shader all passed; desktop/media/network opt-ins disabled).
- python3 scripts/check_renderer.py -> OK (exit 0; backdrop_geometry_test, backdrop_scene_test, hdr_output_gpu_test, unchanged_present_test, metal_scene_draw_smoke, 12 generated cases + reload cycles; 7 local-asset/corpus tests skipped).
- python3 scripts/test.py -> OK (all 37 Python test files passed; native unit/integration 5423 passed, 0 failed, 70 skipped; initial run had 1 unrelated PixivStoreTests timeout before clean rerun).
- Gaps: live desktop, lock-screen, Mission Control and panel visual appearance not inspected on a display (no authorized desktop run); Release app not rebuilt.

## 2026-11-26 — Lock-screen hover cursor reactivity (#266)

- Added Shared/LockScreenPointerTracker.swift, DOM hover delivery in WebWallpaperProtocol/ScreenSaverWebSurface, and extension hover tracking in WallpaperSurface/WallpaperController for active lock-screen Scene and Web surfaces.
- Targeted: python3 scripts/test.py --only LockScreenPointerTrackerTests (5/5 passed), ScreenSaverWebSurfaceTests (19/19 passed), WebWallpaperPageMessageTests (3/3 passed).
- Gate: python3 scripts/test.py — all 37 Python test modules OK; native suite 5422 passed, 0 failed, 70 skipped of 5492 (182s).
- Skips/gaps: 70 pre-existing skips in full suite; Release app not rebuilt; live macOS lock-screen cursor updates inside the sandboxed WallpaperMachineExtension were not exercised on a locked desktop.

## 2026-11-26 — Prewarm the optimized Xcode compiler outside the release path

- The five successful Version runs v1.11.1–v1.15.0 had a median elapsed time of 24m16s. For v1.15.0, Xcode took 11m19s; about five minutes waiting for the macOS runner and 1m41s for packaging/notarization are not addressed by a compiler cache.
- Headless arm64 replay on Xcode 27.2 beta (27B5019j), using the workflow's warm and unpack commands, existing renderer archive and pinned Sparkle dependency, and fresh DerivedData each time: cold Release 221.1s (0/174 hits); a version, history and public-key change restored all 174 jobs in 9.6s. The 174.3 MiB snapshot unpacked in 1s locally; no GitHub transfer or runner queue was measured.
- One Swift edit in a disposable copy of the extension caused one miss: 173 hits, 16.5s. Checked the linked extension for the new and not the old string; checked the new marketing/build versions in both plists, the current public key, feed URL, bundled changelog and fresh ad-hoc code signatures. Neither build used a cached app.
- Ran the unpack step with a damaged archive: no compiler directory was handed to Build. Exercised legacy, cold Sparkle and warm Sparkle build arguments, identical keys across version bumps and separate prefixes across Xcode builds. Actionlint and shellcheck accepted the changed workflow paths with actionlint 1.7.12's known exception for the unchanged publish concurrency option (queue: max).
- python3 scripts/test.py --serial (the hosted native CI mode): all 747 Python tests and 5,408 native tests passed; 70 native cases skipped. Two preceding parallel runs failed different pre-existing timer-order, GPU sampling and SteamCMD fixture PID assertions; the timer-order case also passed in isolation. No assertion, selector, signing or publication gate was changed to get a pass.
- A hosted macOS 15/Xcode 26.3 warm-up, nonpublishing signing/notarization rehearsal, and end-to-end hosted timings still require the workflow changes on GitHub; no release or tag was created.

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
