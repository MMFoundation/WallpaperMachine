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

## 2026-11-12 — Menu bar energy use (issue 188)

- Added Settings → General → Show energy use in the menu bar (off by default) and an Energy use row in the menu bar panel, both from one MenuBarEnergyMeter (5 s for the figure, 2 s with the panel open, nothing while unattended).
- Targeted: python3 scripts/test.py --only MenuBarEnergyMeterTests --only EnergyReadoutTests --only StatusPanelControllerTests --only StatusPanelRenderTests --only WallpaperPresentationPolicyTests --only SettingsSectionsRenderTests --only EnergyUsageMonitorTests --only WallpaperBackupTests: 155 passed.
- Gate: python3 scripts/test.py: 4897 passed, 0 failed, 68 skipped.
- Not checked: the status item drawn in the real menu bar (no desktop run, no Release build); the figure's width beside other menu bar items.

## 2026-11-12 — Integrate Steam sign-in retry recovery

- Integrated the fix from fix/steam-sign-in-retry-186 onto current main; removed an obsolete sign-in-only assertion and documentation after that API was removed.
- `python3 scripts/test.py --only PanelDownloadActionsTests --only DownloadDialogResolutionTests --only DownloaderFailureOutputTests`: 42 passed, 0 failed, 0 skipped.
- Initial full gate: 4888 passed, 1 failed, 68 skipped; the welcome accessibility regression also failed on unchanged main. Fixed separately in a1f9824.
- `python3 scripts/test.py --only WelcomeRenderTests --only FirstRunModelTests --only PanelDownloadActionsTests`: 59 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py` after the welcome fix: Python checks passed; 4889 native tests passed, 0 failed, 68 opt-in media/network/reference checks skipped.
- Steam timeout/password rejection, corrected-account retry, QR recovery through import, an existing QR session, and normal transfer retries were exercised with offline fakes.
- Live Steam sign-in, the reporter’s network/account, desktop interaction and VoiceOver remain unverified. No Release build or renderer changes.

## 2026-11-12 — Control panel UI critique fixes (ws1-ws7) on claude/ui-critique-fixes

- Scope: 34 local commits over main 54227ed3: Apply/Play symbols and wording, Workshop inspector Apply and Command-Return, staged-edit footer and Not applied marks (Rust bridge staged flags), collapsible display cards, welcome Skip setup and the delayed support prompt, P3 polish, and the panel type scale, shared buttons, scrims, tile marks and design-token lint.
- python3 scripts/test.py on the final tree: 4887 passed, 0 failed, 68 skipped; script tests incl. test_panel_design_tokens, catalogs and doc links OK. Each workstream also passed the full gate before its commits.
- Known flake seen once under full-gate load: WebWallpaperPageTests.testRefusedOrReplacedNavigationDoesNotFailTheWallpaper (10 s WebKit deadline) in ws3's first run; the rerun passed. Not caused by this branch.
- python3 scripts/check_rust.py after the bridge change: core 429, bridge 961, shader 958 and core-integration passed, 0 failed; desktop-window tests excluded (need an authorized desktop run). No Rust or bridge change since.
- python3 scripts/check_renderer.py on the final tree: exit 0; 12 generated scenes pixel-equal pooled vs isolated, 0 reload cycles; 19 local-corpus and energy checks skipped (no corpus or opt-ins), so asset coverage is skipped, not passed.
- Not rendered: no Release build, no app launch, no screenshots. Unverified by eye: paused vs waiting rings, scrim strengths, the new markHeart pink and the library mark's contrast, the translucent secondary fill in dark mode, the View menu titles, the welcome Skip setup and Escape routing.
- Not covered by tests: whether a click (not a key) focuses a tile and makes its ring show the cancel mark instead of the percentage; pixiv Command-Return wiring (manual smoke only); the scope bar's middle tier; translations without native-speaker review.

## 2026-11-11 — Feeling good? offers Sponsor on Open Collective; README lists Open Collective sponsors

The support prompt's second choice opens MMFoundation's Open Collective (approved by Open Source Collective on 2026-11-11) instead of the website's pricing page, with new strings in every shipped language; the four READMEs gain a sponsors block drawn by Open Collective.

- `python3 scripts/build.py --renderer-only` — OK; the checkout's `libwallpaper_bridge.a` predated main's Steam QR sign-in bridge, so the first targeted build failed to link
- `xattr -cr build/Build/Products/Debug` — cleared after the extension's CodeSign refused Finder/File Provider attributes (docs/build.md)
- `python3 scripts/test.py --only SupportPromptPresenterTests --only PanelSupportPromptTests --only PanelPerformanceDataTests --only ExternalLinkTests` — 32 passed; `--only PanelSharingTests` — 5 passed
- `python3 scripts/test.py` — exit 0: every Python suite, XcodeGen, and 4,843 native tests passed, 0 failed, 68 skipped of 4,911 (two main-thread API runtime warnings)
- Not checked: the sheet's longer row in six languages on screen (no desktop run, no Release build); the README block through GitHub's image proxy (rendered with GitHub's Markdown API, images loaded from Open Collective directly)

## 2026-11-11 — Wallpaper-switch teardown and lock-screen recovery (issue 184)

- `python3 scripts/test.py` in an isolated HEAD checkout plus this patch: 687 Python tests passed; native gate 4,741 passed, 66 skipped, zero failures. The shared checkout was blocked by its pre-existing missing `CLAUDE.md`; an earlier targeted build also encountered concurrent desktop-widget API edits.
- Native result: one main-thread runtime warning, attributed by the detailed xcresult issue to `AppUpdateTests.testSignatureCheckRefusesAnUnsignedOrAlteredCopy()`; no source location.
- `scripts/check_renderer.py` entry point with its output redirected to the task directory: 3,520 passed, seven local-asset/opt-in tests skipped; all 12 generated image comparisons and eight projects with two reload cycles passed. GPU and cadence checks ran; timer diagnostics were collected.
- `python3 scripts/check_rust.py`: all four groups passed (2,499 tests); five desktop-window cases were explicitly excluded, and desktop/media/network opt-ins remained disabled.
- The retiring-renderer acknowledgement regression and the pending-Metal-command release regression failed before their respective fixes and passed afterwards. Interrupted refreshes and genuine repeated renderer exits remain covered.
- No live desktop run, Wallpaper Engine comparison, or Release app build. The exact Apple Metal HUD crash on the reported macOS build remains unverified; tests cover the identified teardown and acknowledgement races.

## 2026-11-11 — Review fixes for the Steam QR sign-in and native downloads

Addresses the PR review: CM logon cleanup, endpoint fallback and cancellation; HTTPS-only content servers with failover promotion; Workshop app check; free-space check from the manifest size; QR actions through PanelController and cancelled when the dialog closes; localized native failure messages.

- `python3 scripts/test.py` — 4839 tests: 4767 passed, 70 skipped, 2 failed: WebWallpaperErrorStackTests/testStacksReadAsV8WritesThem and WebWallpaperWindowCompositionTests/testPreservingLiveSurfacesLeavesOtherWindowPoliciesIntact, both failing the same way on main on this Mac
- `python3 scripts/test.py --only SteamCMConnectionTests SteamContentClientTests NativeWorkshopDownloadTests SteamQRSignInTests SteamKeyValuesTests WorkshopStoreTests DownloadQueueTests` — 58 passed, including 10 new tests (logon cleanup, endpoint fallback, cancellation, wrong app, free space, server promotion, HTTPS-only servers, joined logon failure, message mapping)
- `python3 -m unittest scripts.tests.test_localization_catalogs scripts.tests.test_panel_localization` — 17 passed
- Not covered: live Steam and the UI were not rerun after these fixes

## 2026-11-11 — Desktop widgets: seven more kinds

- Added Text, Countdown, Greeting, Battery, Sunrise and sunset, Analog clock and Month calendar widgets; clocks and dates gained Time zone and Label, dates gained month-year, week and day-of-year styles and other calendars.
- python3 scripts/test.py --only DesktopWidgetTests --only DesktopWidgetControllerTests --only WidgetsSettingsTests --only LowBatteryTests --only SettingsSectionsLocalizationTests: 49 passed.
- python3 scripts/test.py: 4779 passed, 66 skipped, 0 failed (run with CLAUDE.md restored temporarily; the working tree has it deleted, which fails test_doc_links).
- Not checked: how the clock face, month grid and multi-line text look on a real desktop; no Release build.

## 2026-11-11 — Desktop widgets

Clocks and dates drawn on the desktop over any wallpaper (Settings › Desktop Widgets); see [desktop widgets](../features/desktop-widgets.md).

- `python3 scripts/build.py --renderer-only` — OK; the renderer library was stale against the committed bindings (`set_audio_gain`), rebuilt so the app links
- `python3 scripts/test.py --only DesktopWidgetTests --only DesktopWidgetControllerTests --only WidgetsSettingsTests` (plus the Settings search, localization and window render classes) — 45 passed
- `python3 scripts/test.py` — exit 0; Python stage OK; 4831 native tests: 4765 passed, 66 skipped, 0 failed
- The Settings page was drawn off screen in light and dark and checked by eye; the Arrange picture matches the desktop geometry
- Not checked: widget windows on a real desktop (over scene, video and web wallpapers, across Spaces, with the notch strip, after sleep); no desktop run was authorized. No Release build

## 2026-11-11 — Reduce volume while another app plays sound (issue 182)

Adds Reduce volume beside Mute under When another app plays sound, with a Reduce volume to slider (0% to 100%, default 30%). The bridge gains a transient audio gain (set_audio_gain) multiplied into each saved volume for scenes, web pages and native video; no saved volume is rewritten.

- `python3 scripts/build.py --renderer-only` — exit 0; renderer built and Swift bindings regenerated (one added call, `setAudioGain`).
- `python3 scripts/check_rust.py` — exit 0; 2,499 passing tests (core 429, bridge 956, core-integration 20, shader 1,094), 0 failed. Five desktop-window tests explicitly excluded; desktop/media/network opt-ins disabled.
- New bridge tests: the gain scales an open scene's volume live and restores the saved one, a volume or a mirror's volume changed meanwhile is saved whole and played reduced, a wallpaper applied meanwhile starts reduced, web and native-video descriptors carry the product, a display refresh does not reload a turned-down scene, and a gain outside 0 to 1 is refused.
- `python3 scripts/check_renderer.py` — exit 0; all 12 generated scenes matched between pooled and isolated runs; seven local-asset-dependent cases skipped.
- `python3 scripts/test.py` — exit 0: all 32 Python suites, XcodeGen, and 4,739 native tests passed, 0 failed, 66 skipped of 4,805, the skip count of the gate runs logged before it (opt-in media, live Steam and reference jobs). An earlier targeted run failed in CodeSign on build-product extended attributes; `xattr -cr build/Build/Products/Debug`, as [build](../build.md#troubleshooting) says, cleared it.
- Three runtime warnings, all the known main-thread one (a method that should not be called on the main thread); none was traced to this change.
- New native tests cover the level preference (default, range, corrupt values, reset, one change posted), its backup validation, the policy's gain channel (only while other sound plays and Reduce volume is chosen, a new level delivered while the rule holds, mute still silences, refused delivery retried, teardown restores) and the panel row (offered beside Mute, shown only while chosen, out-of-range refused).
- Not checked: the lower volume was not heard on a real output, and the slider was not operated in the running app; no desktop automation and no Release build. A [manual smoke](manual-smoke.md#audio-responsiveness) item covers both.

## 2026-11-11 — Workshop inspector removal (#183)

- Added Move to Trash for installed Workshop items using the existing confirmed library removal action; collections remain open-only.
- Reused the existing label and translations in all shipped app languages; documented removal in workshop-downloads.md.
- python3 scripts/test.py --only WorkshopInspectorTests: 13 passed.
- Initial full gate blocked by the pre-existing deleted CLAUDE.md documentation link; temporarily restored its relative symlink for validation.
- Parallel full gate: 4722 passed, 5 timing/session failures, 66 skipped.
- python3 scripts/test.py --serial: 4727 passed, 0 failed, 66 skipped; one runtime warning.
- Opt-in media/network and desktop UI checks were not run; visual behavior was not manually checked.
