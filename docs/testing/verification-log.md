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

## 2026-11-16 — PR #218: resilient capture publication

- PR #218 follow-up: isolate per-display registration errors and verify actual capture ownership before skipping publication repair; no polling or per-frame work.
- The partial-registration regression failed before the fix because the second display retained no owner. Synchronization now attempts every handle and shared demand while preserving the first error.
- The independent-review between-writes schedule was reproduced in the real bridge actor with the worker held after capture registration but before its response write; the descriptor matched while ownership was absent.
- Publication now reads the capture controller through its existing serialized worker lane. Healthy registrations are not repeated; the read does not query permissions or start/restart hardware.
- Nine targeted Rust tests passed, including both new failure regressions, capture-lane read idempotence and the existing saved-audio initializes-once contract.
- `python3 scripts/check_rust.py` passed on the combined source: core 436, bridge 978, integration and shader suites all passed. Five desktop-window cases excluded; the primary-display sanity probe explicitly skipped with no active display; live media/network opt-ins off.
- `python3 scripts/build.py --renderer-only` passed. `python3 scripts/test.py`: 718 Python tests and 5,071 native tests passed, 70 native skips, zero failures; two runtime warnings plus compiler/linker warnings remain.
- `python3 scripts/check_renderer.py`: 3,530 tests passed, seven optional corpus/media skips; all 12 synthetic pixel cases and reload cycles passed. The earlier pipeline was deliberately stopped before the combined correction and is not final-source evidence.
- The combined pipeline survived a device disconnect; surviving processes and exact-source logs were checked before continuing. No duplicate suite was started. Heavy processes were confirmed absent before releasing the shared Mac slot.
- No Release app, live audio/player test, permission prompt, desktop action or energy measurement. Media replay remains driven by host reconciliation; automatic surface recovery without a snapshot waits for the next reconciliation trigger.

## 2026-11-16 — Issue #215: audio startup and media replay

- Issue #215: repair activation-time audio capture and replay system media to a replacement renderer on a retained display handle; no wallpaper-specific conditions or per-frame work.
- Both audio ordering regressions failed before the fix (capture left suspended; response/registration overwritten); the same-handle media replay regression also failed before comparing renderer load IDs.
- Targeted native media tests: 23 passed. Targeted bridge operation/audio/media tests: 168 passed, including the new media-instance consent and presentation test.
- `python3 scripts/check_rust.py` passed: core 436, bridge 975, integration and shader suites all passed. Five desktop-window tests excluded; live media/network opt-ins disabled.
- `python3 scripts/build.py --renderer-only` passed and regenerated Swift/FFI bindings from the changed bridge API.
- `python3 scripts/test.py` ran once as the final routine gate: 718 Python tests across 35 modules and 5,071 native tests passed; 70 native skips, no failures. Four main-thread runtime warnings had no source location; compiler/linker warnings also remain.
- `python3 scripts/check_renderer.py` passed: 3,530 tests, seven optional corpus/media skips; all 12 generated pixel cases and reload cycles passed.
- `we_reference.py capture/render/compare` used Wallpaper Engine frames for the reported item. Static before/after output was unchanged: MAD 32.90/33.68 and off48 25.5%/26.1% versus the two references. Existing scene-image differences remain; muted static captures do not verify live music or capture startup.
- The actual wallpaper rendered synthetic song/artist/cover input with 63 generated spectrum bars, nonzero audio response and zero script errors. Lifecycle regressions verify the host fixes without opening an audio device.
- No Release build, installed-app restart, live player, system audio capture, permission prompt or Mac desktop test. The VM was already running for another task and was returned to that task after capture.

## 2026-11-16 — Replaceable shared state in scene scripts

- Issue #216: allow a scene script to replace shared state so media visibility switches reach other scripts; no per-frame work added.
- The new generic shared-state regression failed before the fix; all three focused shared-state tests passed afterwards.
- Wallpaper Engine origin probe: mean pixel error 50.12 → 0.37; pixels differing by more than 48: 20.4% → 0.4% for both captures.
- Reported wallpaper with synthetic song/audio: media panel returned from x=-1200 to x=2000; all 63 cloned spectrum bars regained width, with nonzero heights in the injected tone bands.
- Reported wallpaper without media: reference mean error 8.14 → 7.46 and 3.79 → 3.11; unchanged background animation still prevents pixel identity.
- python3 scripts/test.py: 35 Python modules passed; 5070 native tests passed, 0 failed, 70 skipped; 3 runtime main-thread warnings.
- python3 scripts/check_rust.py: core, bridge, core integration and shader checks passed; five desktop-window cases excluded.
- python3 scripts/check_renderer.py: registered checks and generated pixel/reload probes passed; optional corpus/media/energy inputs skipped.
- Windows reference VM suspended after capture. Live player/audio capture unverified; #215 and #202 remain unresolved. No Release build or app restart.

## 2026-11-15 — Independent-display wallpaper volume and mute

Issue #213: optional per-wallpaper, per-display sound choices inherit existing wallpaper defaults until set; mirror settings and temporary playback rules are preserved.

- Regression proof: the previous implementation returned global volume 0.8 and unmuted instead of the left display choice 0.2 and muted. Seven focused Rust cases passed after the change.
- python3 scripts/build.py --renderer-only: passed; regenerated the Swift bindings through the build pipeline, including trailing-whitespace normalization.
- Targeted native display, wallpaper-settings and status-panel suites: 43 passed, no failures or skips.
- python3 scripts/check_rust.py: all checks passed; 2,523 tests in the printed summaries, with five explicitly excluded desktop-window cases and desktop/media/network opt-ins disabled.
- python3 scripts/check_renderer.py --skip-build: full rerun passed with 3,529 tests passed and seven asset-dependent checks skipped; all 12 synthetic scenes and 16 reload cycles passed. The initial run failed one NV12 readiness case, which passed in isolation and in the full rerun.
- python3 scripts/test.py: all 35 Python modules passed; 5,070 native tests passed, 0 failed, 70 skipped; one runtime warning. The initial full run timed out in an existing lock-screen readiness test; its isolated check and full rerun passed without source changes.
- Build-script, localization and Markdown-link checks and git diff --check passed. The app help is translated into all six shipped languages.
- No live multi-display sound or desktop interaction check, Release app build, installation or restart.

## 2026-11-15 — Retry native selection before a raced store write

Refs #198. This implements bounded pre-write retries; historical-Space scaling and main-actor work remain open.

- Regression proof: five new or updated race scenarios failed on the previous implementation.
- Targeted selection, service and shared-store suites: 187 passed; focused restoration and reload checks: 2 passed.
- python3 scripts/test.py: all 35 Python test modules passed; 5,069 native tests passed, 0 failed, 70 skipped; two runtime main-thread warnings.
- An earlier parallel gate timed out in the Workshop filter layout matrix. Serial diagnosis also exposed a poster assertion before publication finished; test-only fixes wait for publication, traverse the accessibility tree once and split the appearance matrix.
- git diff --check and scripts/tests/test_doc_links.py: passed.
- Synthetic stores and injected services only. No live wallpaper or lock-screen test, Release build, app installation or restart.

## 2026-11-15 — Installed wallpaper resolution and full tags (#205)

- Installed rows join cached public Workshop tags with local manifest facts, removing case-insensitive duplicates; metadata updates invalidate the row cache without creating update badges.
- The inspector shows local video dimensions including rotation, original packaged-image dimensions or a loose scene's fixed canvas; otherwise it uses Steam's resolution tag and omits unknown dimensions.
- Workshop details survive relaunch, remain available offline and are refreshed for a selected item when missing or day-old, independently of automatic update checks; update checks and downloads also populate the cache.
- Deletion, reinstall, selection changes and panel closure invalidate pending detail reads; edited manifests are remeasured on library refresh.
- Targeted native run: 63 passed, 0 failed; full gate also covered the subsequently added selection-cancellation case. Header checks covered six languages and both appearances in a 320-point column.
- python3 scripts/test.py: 35 Python modules passed; native 5,064 passed, 0 failed, 70 skipped (opt-in checks).
- Three runtime main-thread warnings came from VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne, WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength and AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy; no warning was attributed to the added tests.
- A read-only public Steam details request returned a 3840 x 2160 tag and all 10 tags for a scene, including Puppet Warp and Media Integration.
- git diff --check passed; 116 local documentation link targets exist. XcodeGen regenerated the project for the two new Swift files.
- No Release build or live desktop interaction; packed/automatic scenes and unreadable local formats depend on known Workshop resolution tags.

## 2026-11-15 — Workshop Application and Asset filters (#206)

- Application and Category → Asset are visible, independent checkboxes, excluded by default; Clear restores those defaults.
- Regression first: the previous implementation failed three targeted tests because the options were absent.
- Targeted filter, browser model and download-policy tests passed; the added offscreen layout case passed in all six shipped languages, both appearances and 760×560 / 1240×800 windows.
- python3 scripts/test.py: 35 Python modules passed; native tests 5,050 passed, 0 failed, 70 skipped (opt-in checks).
- One runtime warning came from AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy: a method was called on the main thread. No warning was attributed to the filter tests.
- Read-only anonymous Steam queries: Asset returned 30 tagged rows and a total of 1,290; Application returned no rows, so live Application results were not verified.
- git diff --check and 17 local link targets in the owning Workshop document passed.
- No desktop run or Release build; live visual interaction and Application search results remain unverified.

## 2026-11-14 — Continue playback after deleting wallpapers (#207)

- Deleting an active wallpaper now restores that display’s recent playable wallpaper or continues its playlist; batch exclusions, mirrors, failed trash moves and failed replacements are covered.
- Both initial deletion regressions failed before implementation. Targeted deletion, playlist, panel and display checks passed: 118 tests.
- First full run: 5047 native tests passed, 1 fixed-delay fullscreen-occlusion test failed, 70 skipped. The untouched baseline then passed 5032 native tests with 70 skipped; no occlusion code or test was changed.
- Final python3 scripts/test.py: all Python suites passed; 5048 native tests passed, 0 failed, 70 opt-in tests skipped.
- Three main-thread runtime warnings were attributed to existing video-decoder, video-format and update-signature tests; all passed.
- Deletion confirmation and playback-recovery errors are translated into all six app languages. No live desktop check or Release build.

## 2026-11-14 — Recover orphaned lock-screen selections (#204)

- Reproduced both regressions before the fix: startup skipped archived originals without a live journal, and a Desktop recovery error disabled an otherwise usable screen saver.
- Targeted LockScreenWallpaperTests and LockScreenWallpaperServiceTests: 157 passed; two additional recovery and startup integration regressions also passed.
- python3 scripts/test.py: all Python suites passed; 5032 native tests passed, 0 failed, 70 opt-in tests skipped.
- One native runtime warning came from AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy; no test failed.
- Recovery preserves manual and foreign selections, journals a verified system-image fallback before writing, and runs the orphan scan only during recovery.
- No live lock-screen or screen-saver run and no Release build; the reporter’s exact system wallpaper store was not included in the diagnostics.

## 2026-11-14 — Compact pixiv pages after filtering

- Matching works are deduplicated and paginated after filtering; rankings report exact matching totals and searches refill on demand with lookahead.
- Targeted pixiv store and panel regression run: 84 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py`: exit 0; all Python script modules passed; native tests: 4,933 passed, 0 failed, 70 skipped.
- Seven new pagination cases cover cross-page refill, cached refiltering, search lookahead, retry, duplicates, empty ratings, in-flight filter changes and a fully filtered tail.
- Opt-in media, live-network and snapshot checks remained skipped. Two runtime main-thread warnings were reported by the full suite.
- Live pixiv and desktop presentation were not checked; no desktop control, Release build, installation or restart was performed.
