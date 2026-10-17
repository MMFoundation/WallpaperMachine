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

## 2026-10-17 — Native Metal parity and cost before the Vulkan path is deleted

Lane metal, phase 2c on a worktree of b6daf0b6: measurements only, no code change. Headless; no desktop, lock screen, audio or app launch. The 67 scene wallpapers of the local Library were read, not changed.

- Admission, `metal_scene_draw_smoke` once per scene (`WE_TEST_METAL_PROJECTS`, `WE_TEST_METAL_FRAMES=2`, `LocalProjectsNamedByTheEnvironmentRunThroughTheNativeBackend`): 67/67 Native Metal, 0 `Compatibility --`, 0 `Compatibility after prepare --`, 0 `metal translation of`, every process OK (60/60 on 2026-10-13, 64/64 in 2b).
- Poster parity, `LocalProjectsDrawTheSamePictureOnBothRenderers`, 12 batches of at most 6 scenes, `WE_TEST_METAL_WARMUP_TICKS=40`, `WE_TEST_RANDOM_SEED=1`, `WE_TEST_METAL_FRAMES=180`, 960x540: 39/67 byte-identical, 65/67 with mean absolute difference under 0.05/255 (the 2026-10-13 criterion, 57/60); worst 0.99 (3675966045) and 0.57 (3616389236), the same two scenes as then (0.26, 0.06). The 28 others were run a second time to separate run-to-run noise and each is explained.
- 17 scenes differ by exactly 1 level on 1 to 240 pixels (float rounding between the two shader compilers); 9 differ only inside the wall-clock text both renderers also change between two runs of the same renderer (clock digits, an FPS counter), plus 1-level pixels on one of them.
- 3616389236: the spinning globe is a sprite sheet and its phase differs, because a clock digit changing width rebuilds the graph at a wall-clock moment and the rebuild restarts the sheet (trace on Compatibility: frame 33 back to 1). Runs in which neither renderer rebuilt draw the globe identically (0 pixels), runs with a Compatibility rebuild differ on 1400 to 1850 pixels. Host behaviour of both renderers, not a rendering difference.
- 3675966045: its fluid simulation (a feedback simulation, line emitter) is chaotic. Byte-identical on both renderers with that effect removed from an unpacked copy (mean 0.000, 0.993 with it); identical for the first 10 frames; Native differs from itself by mean 1.04 to 1.16 (1.9 to 2.1% of pixels over 48) when the frame step changes by 3e-8 s, as much as Native against Compatibility (0.99, 1.7%).
- Cost, `UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly`, 6 scenes at 3840x2160 and 60 FPS, 5 s warm-up and 15 s windows, warm caches, one renderer per process, C N N C then repeated (2 to 6 runs each, `/usr/bin/time -l` for peak). Per frame, Compatibility to Native: CPU 3.64 to 3.35 ms (3226487183), 2.75 to 2.31 (3620484312), 3.17 to 1.75 (3675966045), 2.54 to 2.26 (3657295614), 2.17 to 2.29 (3013702957, +6%, medians 2.24 to 2.18, spread 1.57 to 2.82), 127.6 to 44.0 (3589454154); GPU 19.8 to 5.5 ms, 5.15 to 4.90, 7.81 to 7.03, 5.17 to 5.15, 5.42 to 5.16, 9.7 to 11.1 (+14%); command buffers per frame 3 to 1 (118 to 1.6 on 3589454154). Compatibility holds 37 FPS on 3226487183 and 7.4 on 3589454154 where Native holds 60 and 20.
- Footprint, same runs. End of window, Compatibility to Native: 6479 to 7132 MB (3226487183, +10%; Compatibility's end value swings 6402 to 7176 MB between runs, Native's is constant at 7114 to 7151 and was 7148 on a 2026-10-14 build), 792 to 757, 902 to 882, 1014 to 981, 623 to 594, 1603 to 1705 (3589454154, within Native's own 1494 to 2162 spread). Process peak: 8256 to 7118 MB (-14%), 884 to 1372 (3620484312, +55%, a load transient: the 2026-10-14 build measured 1191 to 1618), 903 to 1035 (one Native run 1207, the other 864), 1014 to 1069, 623 to 635, 2425 to 2360.
- Found, not caused by Native Metal: 3589454154 (perspective, 7 puppets, 17 texts) asks for a graph rebuild about every 5 draws on both renderers (43 Compatibility and 41 Native rebuilds in 180 draws), so each frame pays texture decoding and uploads again; the 2026-10-14 build held 60 FPS at 14 ms CPU and 4.8 ms GPU per frame on it, the current tree 7.4 FPS (Compatibility) and 20 FPS (Native). Its GPU figure above is that rebuild cost, not a steady frame. Not bisected.
- Not run: lock screen and screen saver on Metal (recorded in 2b), desktop or UI tests, Release build, WE reference frames.

## 2026-10-17 — HDR scene video tone mapping and the Native-Metal-only hold policy

- Commits 1d85361d, 4dfbcf4b (10-bit and HDR video textures tone mapped to SDR) and 008783df, 8e9d3bae, 4fc7856d, 01222d8f (wmSurface, the Native Metal only failure policy, panel, lock screen) integrated onto b7ac57c1.
- build.py --renderer-only rc=0 and regenerated bindings identical to the committed ones; check_rust.py rc=0, 1527 passed, 0 failed; asset and corpus tests skipped.
- check_renderer.py rc=0: no FAILED test in any evidence log, report.json has no nonzero count, 2124 engine tests passed, all generated-scene cases pixels_equal, reload cycles 0; local-corpus and local-clip tests skipped.
- test.py rc=0: 3897 passed, 0 failed, 46 skipped of 3943, Python suites and native unit tests (app target) included.
- Lane evidence: P010ConvertedMatchesCpuReference against a standards-based double reference; ATenBitVideoLayerStaysOnNativeMetalAndIsToneMappedToSdr with real HEVC Main10 PQ, HLG and BT.709 clips; scene_failure_policy_test covers admission, prepare, compile, frame, surface and a refused reload.
- Not checked: the real lock screen and screen saver, a real HDR display or any HDR file from the library, container mdcv/clli boxes, Dolby Vision profile 5, the held-scene look on a desktop; a scene that fails to parse still waits 90 s and rolls back.
- Not run: Release build, desktop or UI tests.

## 2026-10-17 — Own WebM player, plain video native-only, Video backend setting removed

Lane ext (phase 3b/3c) on a worktree of b7ac57c1: WebMReader and the WebM player (desktop and lock screen), plain video never reaches the scene engine, the Video backend setting is gone. Headless only: no desktop, lock screen or audio hardware.

- `python3 scripts/check_rust.py` — exit 0 (bridge lib tests, core, integration, shader); asset and corpus tests skipped (no WE assets dir, no unpack corpus)
- `python3 scripts/build.py --renderer-only` — passed after every Rust/C++ change; bindings regenerated and committed
- `python3 scripts/check_renderer.py` — exit 0, no failed test in any evidence log; webm_reader_test, sound_matroska_tests, vt_frame_decoder_test, media_matroska_tests all pass
- `python3 scripts/test.py --only <class>` for WebMOpening/WebMPlayer/WebMVideoWallpaperWindow/LockScreenWebMPlayer/LockScreenVideoPlanner/VideoFormatSupport/NativeVideo*/WallpaperActivationRecovery/WallpaperCompatibility/Panel*/Settings*/LockScreenWallpaperService — all passed; 38 opt-in NativeVideoPlayerMediaTests skipped
- `python3 -m unittest discover -s tests` (scripts/) — 376 tests OK
- Cost probe (temporary, removed): 1080p/30 fps VP9 WebM in WebMPlayer 1.52% of one core, H.264 MP4 in AVPlayerLayer 1.38%, idle host 0.19%, about 29-30 MiB each, headless layer, no audio. The old scene-engine path was not measured (needs a running desktop).
- Not verified: WebM window on a real desktop, audio output and A/V sync, rotated clips on screen, HDR, the extension reaching the supplemental VP9 decoder, AV1 hardware decode, M1/M2, real libvorbis WebM, full test.py, Release build.

## 2026-10-17 — Native video default, native scene video textures, scene sounds without FFmpeg

Integration of the plain-video, scene-video and scene-sound lanes on one branch (16 commits over 06c37925), after each lane passed its own gate.

- `python3 scripts/build.py --renderer-only` — exit 0; bridge bindings regenerated with no diff.
- `python3 scripts/check_rust.py` — exit 0; 1524 tests passed, 0 failed (asset and corpus tests skipped: no Wallpaper Engine assets or unpack corpus on this machine).
- `python3 scripts/check_renderer.py` — exit 0; 2083 headless engine tests passed, 0 failed across every registered binary (including video_probe_test, vt_frame_decoder_test, sound_core_tests, sound_apple_tests, sound_vorbis_tests, audio_tests); report.json has no nonzero counter; 20 distinct tests skipped (local corpus, local clips and Workshop projects).
- `python3 scripts/test.py` — first run: 3889 passed, 1 failed (DownloaderLifecycleTests/testSteamCMDInheritsTheStagingClaim, unrelated to this wave, passed alone 47/47); full rerun exit 0: Python 376 tests, native 3890 passed, 0 failed, 46 skipped of 3936.
- Lock screen and screen saver were checked on the real desktop earlier today: AVFoundation video and Native Metal scenes both render.
- Gap: WebM plain videos still fall back to the scene engine until the WebM surface lands; its audio track and any other container FFmpeg still decodes are unchanged.
- Gap: no Release build was made for this entry; the AudioToolbox MP3 decoder clips at full scale where FFmpeg kept float peaks (documented in docs/sound-decoding.md).

## 2026-10-16 — Per-language release banners, bulleted What's New

Each language block opens with its own banner (x.y.z.jpg, x.y.z.zh-Hans.jpg; Chinese falls back to English); What's New swaps the banner with the language tab, bullets list entries with a hanging indent and shows Highlights in the accent colour with ✦ markers. 1.5.0 now has English and Chinese banners.

- `python3 scripts/test.py` — exit 0; 3873 tests: 3828 passed, 45 skipped; test_release_notes.py 62 tests OK
- Visual: temporary on-screen XCTest window with a draft 1.5.0 section, captured in English and Chinese; probe deleted
- Skipped: live --ai model run (no key locally); the draft section was hand-written to preview layout only

## 2026-10-16 — Release banners and highlights in the changelog

Feature releases can carry a bundled 3:1 banner (Resources/ReleaseBanners/x.y.z.jpg) shown in CHANGELOG.md, the GitHub release page and the What's New window; the release-notes model writes Highlights for x.y.0 and groups many commits per area. Banner for 1.5.0 added.

- `python3 scripts/test.py` — exit 0; 3872 tests: 3827 passed, 45 skipped; test_release_notes.py 61 tests OK
- `python3 scripts/test.py --only WhatsNewTests` / `--only AppUpdateTests` — passed while iterating
- Visual: temporary offscreen XCTest snapshot of the What's New window with the bundled 1.5.0 banner (dark), banner above the header at 712 pt, notes below; probe deleted
- Skipped: live --ai model run (no RELEASE_NOTES_API_KEY locally), so the 1.5.0 wording is written by CI at release; the raw.githubusercontent banner URL is checked only by unit test until v1.5.0 is tagged

## 2026-10-16 — Tabs in the title bar, Now Playing bar and one-colour title bar on top of the Filters sidebar

- Rebased onto main's Filters sidebar (69955b77, cf9f5ebe): my own filters panel was dropped; the sidebar now slides from the window's leading edge, and Installed's has the Collections group at its top.
- Window: no window sidebar; Library, Steam Workshop, pixiv and Settings are tabs centred in the title bar (symbols only under 960 points) with the mark, name and version leading; Library has All wallpapers and Favorites chips; Now Playing is a bottom bar whose wallpaper part opens a details popover; Settings searches above its own section list.
- Title bar: macOS 26 draws a band per window column (opaque grey over a page without a top scroll view, its own dark band over the system inspector). The inspector is now an in-page InspectorColumn (260-420, drag to resize) and the Filters sidebar, page and inspector sit in one full-width scroll host, so the bar is one colour.
- Real window (desktop control allowed by the user): Library with Filters sidebar and inspector open, and Settings, sampled 29,29,31 across the whole bar in dark; inspector edge drag resized it.
- Gate: python3 scripts/test.py passed, 3826 passed, 0 failed, 45 skipped. Targeted shell, root, welcome, installed, inspector, pixiv and workshop classes: 160 passed.
- Not run: desktop UI tests (Tests/UI updated, not executed); light appearance not checked on the real window.

## 2026-10-16 — Filters sidebar replaces the Filters popover

- Change: Installed, Workshop and pixiv filters moved from a popover into one shell-level Filters sidebar (FilterSidebar in PanelDetail) that slides out from under the window sidebar; Filter buttons and the sidebar's own top-right button toggle it.
- python3 scripts/test.py: passed, 3829 passed, 0 failed, 45 skipped (Python suites OK).
- New tests: ShellModelTests (one sidebar across library pages, waits out Settings; takes turns with the inspector under 960 pt), ShellRenderTests (sidebar + inspector fit the split view from 1240 down to 760 pt).
- Migrated tests: InstalledBrowserModelTests, InstalledPageRenderTests (sidebar width 268 pt in every language and appearance), WorkshopBrowserModelTests, ShellModelTests support-prompt/popover cases.
- Visual: offscreen snapshot (temporary probe, deleted) confirmed placement beside the page and search bar; offscreen rendering draws no glass, so the glass look and the slide animation were not seen on a real desktop.
- Gap: InspectorRenderTests smallest-window test timed out twice earlier today on the untouched base and passed in this run: flaky, unrelated.

## 2026-10-16 — origin/main's telemetry and sharing carried into the native panel

Main's 103 unpushed commits were rebased onto origin/main, whose 1.4.1 telemetry and sharing commits were written for the web panel the native SwiftUI panel had replaced; their services kept, their web UI rebuilt natively (Storage switch and report, guide draft, three-prompt sheet, Share…, About links).

- `python3 scripts/test.py --only` the ten touched classes (PanelPerformanceDataTests, PanelSharingTests, PanelSupportPromptTests, SupportPromptPresenterTests, SupportPromptStoreTests, FirstRunModelTests, FirstRunDraftTests, Telemetry{Service,Sampler,Client}Tests) — 97 passed
- `python3 scripts/test.py` — exit 65; 3864 tests: 3815 passed, 4 failed, 45 skipped. The 4 are SettingsBRenderTests.testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowIn{English,Japanese,SimplifiedChinese,TraditionalChinese}: they hang laying out Keyboard shortcuts with its links disclosure open, and the English one fails the same way on 820c436a, before the rebase and this port
- `python3 scripts/build.py --swift-only --configuration Release` — built; the binary carries the new Storage rows
- Not checked: the share menu and the sheets on screen (no desktop run authorised), the live website endpoint

## 2026-10-16 — Settings name what overrides a quality or frame-rate choice

Reported as On battery: Keep running still capping wallpapers at 30 fps. The app's log showed the low-battery rule (saved as Reduced quality, level 20%) engaging at 20% charge; nothing in Quick Settings said so, and the Displays and inspector notes blamed Performance settings and linked to a Frame rate limit reading No limit. Quick Settings' Quality and On battery modules, Performance › Effective now and the Displays and inspector frame-rate notes now name the cause and open the page it is set on.

- `python3 scripts/test.py --only QualityReportTests --only QualityPresetTests --only DisplaysSettingsModelTests --only PanelPropertyRowsTests --only PanelLibraryActionsTests --only SettingsSectionsRenderTests --only SettingsSearchTests --only PanelSettingsValuesTests --only SettingsControlsRenderTests --only PanelPerformanceSettingsTests` — 157 passed
- `python3 scripts/test.py` — exit 0; 3819 tests: 3774 passed, 45 skipped (opt-in media and network layers)
- `python3 scripts/build.py --renderer-only` — run first in the worktree to replace a stale bridge library; regenerated bindings unchanged
- Skipped: no desktop run; the new lines were not looked at on screen (render tests lay out the Quick Settings and Performance pages with a throttle in force in every language). Manual check added to docs/testing/manual-smoke.md.
- Gap: a condition's Pause or Stop overriding On battery: Keep running is still not shown in Quick Settings.
