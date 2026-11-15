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

## 2026-11-14 — Shared wallpaper-store coordination (issue 199)

- Implemented a shared FIFO transaction queue for native selection and desktop posters, with bounded verified WallpaperAgent turnover and selection readback.
- Recovery retries preserve unrelated fields and reject foreign selections; cancelled writes and restarts remain admission barriers; both journals survive unconfirmed restoration.
- Poster acknowledgements drain as a batch; native takeover and quit cancel and drain queued poster work before changing ownership.
- python3 scripts/build.py --renderer-only — passed; prepared the missing test-link dependency and regenerated bindings; no renderer source changes.
- Targeted native run across coordinator, lock-screen, desktop, panel-settings and native-video host tests — 436 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — passed all Python modules; native gate: 5017 passed, 0 failed, 70 skipped of 5087.
- Three runtime main-thread warnings came from VideoFormatSupportTests, AppUpdateTests and WebMFilteredVideoSinkTests; compiler warnings remain in existing code.
- Documentation links and git diff --check passed. Live desktop/WallpaperAgent behavior was not exercised; no desktop authorization, Release build, install, commit or push.
- Removed this task’s disposable test result bundles and renderer-build logs after recording the verdicts; retained compiled build outputs.

## 2026-11-13 — Sign-in window hosts and sign-outs the keychain resists

Security report on the Steam/pixiv sign-in (allowlist for the Steam sign-in window; Steam Community and pixiv sign-out emptying a keychain item another build saved, failing only when the session stays). The report's third finding, memory corruption in `SteamCMDRuntimeService.fingerprint` `readlinkat`, was not reproduced: SIL shows `&link` passing the element buffer (`_convertMutableArrayToPointerArgument<UInt8, UnsafeMutablePointer<Int8>>`), and the same pattern ran clean under AddressSanitizer with a 1022-byte target; the code is unchanged.

- `python3 scripts/test.py --only` WebSignInPolicyTests, KeychainGenericPasswordTests, SteamWebSessionTests, WorkshopSourceTests, PixivStoreTests, PanelWorkshopSubscriptionsTests, NativeWorkshopDownloadTests, PanelPixivActionsTests, PanelDownloadActionsTests — 143 passed
- `python3 scripts/test.py` — first run 4980 passed, 1 failed (`ScreenSaverWebSurfaceTests` frame rate 8.7 < 14 under load; 16/16 alone); rerun 4981 passed, 0 failed, 70 skipped
- Not checked: a live Steam or pixiv sign-in and sign-out against the allowlist, and macOS's real answer to emptying another build's item (modelled by `MemoryKeychain`)

## 2026-11-13 — Keep scenes through empty active-display reports

- Issue #196: build each refresh plan from one CoreGraphics report and its captured main-display flag. An empty active list skips reconciliation, retains scenes/assignments/handles and logs once; actual read errors still propagate.
- Two new empty-report regressions failed before the fix, including loss of the secondary scene. Five added regressions cover empty reports, return/disconnect behavior, preserved paused state and renderer identity, coherent primary selection, bounded diagnostics and error propagation.
- Targeted wallpaper-core display tests: 138 passed. `python3 scripts/check_rust.py --output artifacts/issue-196/rust`: all checks passed; Core 436 and Bridge 962 library tests passed, as did all six integration targets and Shader checks. Five real-desktop cases were explicitly excluded and the opt-in window gate remained disabled.
- `python3 scripts/check_renderer.py`: exit 0; 110 executable/probe statuses succeeded, 12 synthetic pooled/isolated comparisons passed and reload cycles passed. GPU and realtime checks ran; the timer diagnostic was collected.
- Renderer coverage gaps: seven optional local video, particle, wallpaper, energy and corpus cases skipped; four pre-existing corpus/benchmark/worker cases remained disabled.
- `python3 scripts/test.py --only DisplayRefreshCoalescerTests --only SystemWakeRevalidatorTests --only WallpaperPresentationPolicyTests`: 96 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py`: all 35 Python modules passed; 4,971 native tests passed, 0 failed, 70 skipped of 5,041. Skips require opt-in media, live Steam/network, reference jobs or snapshots.
- The full native run reported main-thread warnings in unchanged VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne and AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy; both passed. Documentation links and git diff --check passed.
- No real lock/sleep/multi-display wake cycle or wallpaper reference comparison was performed. No Release app was built, installed or restarted.

## 2026-11-13 — Keep settings searches responsive

- Issue #201: retain the settings result view while typing, build result sections lazily, and reset scrolling explicitly; entering/leaving search resets only the list layout.
- Baseline production source d82c4249: refining wallp through wallpaper and back caused 32 additional system-reading refreshes across eight edits. The regression now passes with no additional refreshes.
- Same offscreen Debug fixture, 760 x 560 points, eight query edits: mean update time 315.52 ms before, 45.75 ms after; maximum 341.32 ms before, 47.01 ms after. Each sample includes a fixed 30 ms settle wait; this is not a live keyboard-latency or Release benchmark. Search calculation remained about 3.1 ms.
- `python3 scripts/test.py --only SettingsSearchRenderingTests --only SettingsSearchTests --only SettingsSearchOfferTests --only DisplaysSettingsSearchTests --only SettingsSectionsRenderTests/testSearchResultsOfTheSixPagesLayOutInTheNarrowColumn --only SettingsWindowRenderTests/testEverySectionFitsTheSmallestWindowAtEveryHeightWhileMovingBetweenSections`: 30 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py`: all 35 Python modules passed; 4,971 native tests passed, 0 failed, 70 skipped of 5,041.
- Skipped checks require opt-in media, live Steam/network, web reference jobs or panel snapshot output. Two main-thread runtime warnings came from unchanged LockScreenWebMPlayerTests.testAFailureTheClipHadBeforeAHandlerWasSetIsHeldAndDeliveredOnce and AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy; both passed.
- `git diff --check`, `python3 scripts/tests/test_doc_links.py`, and `python3 scripts/tests/test_panel_lazy_lists.py`: passed. XcodeGen registered the new render-test file.
- No real desktop interaction or screenshots; windows stayed unordered. No Release app was built, installed or restarted.

## 2026-11-13 — Preserve desktop originals after native restoration failures

- Issue #197: keep poster synchronization suspended until native restoration succeeds; reject native desktop selections when recording poster originals and preserve the existing recovery journal.
- Regression run on the previous implementation: 4 expected failures and 1 passing control across the five selected desktop/lock-screen tests.
- `python3 scripts/test.py --only DesktopWallpaperTests --only LockScreenWallpaperServiceTests --only LockScreenWallpaperTests`: 252 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py`: all 35 Python modules passed; 4,967 native tests passed, 0 failed, 70 skipped of 5,037.
- Skipped checks require opt-in media, live Steam/network, web reference jobs or panel snapshot output.
- The full native run reported main-thread warnings in unchanged AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy and WebMOpeningTests.testAVp9FileOpensWithItsFormatSizeAndLength; both passed. The targeted run reported no runtime warnings.
- `git diff --check` and `python3 scripts/tests/test_doc_links.py`: passed.
- No live desktop/lock-screen/quit cycle was performed; no Release app was built, installed or restarted. Existing incorrectly recorded still-image originals are not migrated from the lock-screen journal; shared WallpaperAgent write/reload coordination remains #199.
