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

## 2026-11-16 — Disable native modes before initial readiness (#193)

- Published display mappings are retained separately from successful-readiness inputs. Either native mode can be disabled during initial activation without a current display UUID, while preserving the other selection and its outstanding first-frame deadline.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests: 89 passed, 0 failed, 0 skipped; the two new cases withhold initial readiness and then remove the UUID before disabling each independent mode.
- python3 scripts/test.py: all Python modules passed; 5100 native tests passed, 0 failed, 70 opt-in tests skipped; two runtime warnings were reported.
- The native gate used the Captain-authorized serial Mac slot, which was released afterward. No renderer/Rust changes or gates; no desktop actions, Release build or installation. This gate predates the separate explicit-error acknowledgement correction.

## 2026-11-16 — Native source lifecycle and inactive preparation fixes (#193)

- Revision-scoped handled exits cannot rearm a stale PID; the existing live-survivor policy remains unchanged. Pending acquire replies survive renderer replacement and complete once for the current generation.
- Invisible existing surfaces defer source preparation until presentation resumes; explicit pending host acquires still receive their readiness frame. The source picker adopts the panel presentation locale.
- Focused service, acquire-reply/policy, presentation authority, registry and panel suites: 128 passed, 0 failed, 0 skipped.
- python3 scripts/test.py: all Python modules passed; 5098 native tests passed, 0 failed, 70 opt-in tests skipped; three main-thread runtime warnings were reported.
- Heavy verification was serialized through the Review PR Captain. No Rust/C++ changes; their gates were not rerun. Callback/policy tests model inactive start counts, not real CAContext delivery or energy use. Live desktop/visual behavior remains unverified; no Release build, install or desktop action.

## 2026-11-16 — Independent native wallpaper source failure isolation (#193)

- Export errors are isolated to the affected native mode; the healthy mode retains its system selection, automatic refreshes and sleeping-display mapping. The unavailable saved choice and error remain visible until it can recover.
- Both new service regressions failed before the fix, reproducing an unavailable lock source disabling a healthy saver and the inverse.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests: 85 passed, 0 failed, 0 skipped, including startup, deletion, refresh, sleep and Retry recovery for both independent modes.
- python3 scripts/test.py: all Python modules passed; 5090 native tests passed, 0 failed, 70 opt-in tests skipped. Two runtime warnings were reported.
- Swift service and tests only; renderer and bridge unchanged from their passing checks. Live desktop transitions remain unverified; no Release build or installation.

## 2026-11-16 — Independent lock-screen and screen-saver wallpapers (#193)

- Added independent saved library choices with Same as desktop defaults, source-aware extension playback, and read-only native exports without changing desktop assignments.
- Focused bridge tests: 8 new independent-export cases and 18 existing activation/export cases passed; python3 scripts/build.py --renderer-only passed and regenerated bindings.
- Focused native settings/service checks: 114 passed; subsequent legacy-manifest, content-selection, diagnostics and GPU-energy checks: 109 passed.
- python3 scripts/test.py: final full gate passed, 5088 native tests passed, 0 failed, 70 opt-in tests skipped; all Python modules passed.
- The first full gate found a legacy-manifest compatibility regression (fixed with version-2 decoding) and a GPU-energy threshold failure; the unchanged energy test passed in isolation and in the final full gate without the renderer suite running concurrently.
- python3 scripts/check_rust.py --output artifacts/issue-193/rust: all four groups passed; five desktop-window cases excluded, desktop/media/network opt-ins disabled.
- python3 scripts/check_renderer.py: passed, 12 generated pooled/isolated comparisons matched, reload cycles passed; seven local-asset cases across five binaries skipped.
- Live desktop/lock/idle transitions, screenshots and UI automation were not authorized and remain unverified. No Release app build, install, commit or push.

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
