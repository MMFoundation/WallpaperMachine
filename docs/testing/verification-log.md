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

## 2026-11-13 — Audio capture startup timeout recovery

Core Audio start receive timeouts now stop and release the uncertain session before one fresh attempt; cleanup failures block replacement. Native status stays typed, and permission advice is limited to authorization errors.

- Injected AudioDeviceStart status 268451843: the new recovery regression failed before the fix (one attempt instead of two). After the fix, targeted cargo tests passed: 60 core audio and 32 audio-worker tests.
- `python3 scripts/check_rust.py --output artifacts/audio-startup/rust` — exit 0 across core, bridge, integration and shader checks; five desktop-window tests excluded, desktop/media/network opt-ins disabled, primary-display probe skipped without an active display.
- `python3 scripts/build.py --renderer-only` — exit 0; renderer library rebuilt and Swift bindings regenerated. No Release app build.
- `python3 scripts/test.py` — exit 65: Python checks passed; native results were 4,925 passed, 1 failed, 70 skipped. InspectorRenderTests/testTheFooterNeverCoversTheRowWhoseEditBringsItIn failed because the footer covered Show the clock; the same targeted test also failed alone. Its fixture uses a test bridge, not native audio capture.
- `python3 scripts/check_renderer.py` — initial build interrupted by a killed backdrop_geometry_test discovery process; rebuilding that target succeeded. The subsequent full run and a final --skip-build run both exited 1 because backdrop_scene_test was killed (signal 9); all other registered binaries returned 0.
- Renderer runs exercised GPU and realtime checks, twelve generated pooled/isolated image comparisons and eight reload projects twice, all successful. Seven local asset/corpus cases were skipped; authored wallpaper compatibility remains unverified.
- Live system audio capture, permission prompts, device changes and desktop behavior were not exercised. No app was installed, launched or restarted. Full native and renderer gates remain blocked by the failures above.

## 2026-11-12 — Desktop widgets workspace: canvas, tabbed inspector, handles, ready-made widgets

- Settings › Desktop Widgets without a search is now a workspace (large canvas, layers, inspector with Content/Text/Style/Position tabs); search still lists every row.
- Canvas: corner handles resize, a knob turns (15° snap, Command free, double click upright), arrow keys nudge, context menu; preview frame raised to 2048 px.
- Ready-made widgets (11 presets, groups laid out by measured size) via a popover and the empty inspector; style swatches replace the Apply Style menu.
- python3 scripts/test.py --only WidgetsSettingsTests: 16 passed (new: handles/nudge, presets layout and limit, inspector tabs, workspace layout at 460/980/1400 in en and ja for every tab).
- python3 scripts/test.py: 4924 passed, 0 failed, 70 skipped.
- Offscreen renders (testSnapshotsOnRequest with TEST_RUNNER_WALLPAPER_MACHINE_WIDGET_SNAPSHOTS) checked by eye in English, dark: empty, each tab, turning, narrow, search.
- Not checked: the live app (no Release build, no desktop run); pointer cursors, real drags and the popover on screen; other languages' renders; light appearance.

## 2026-11-12 — Desktop widgets introduction after an update

A window that introduces desktop widgets once to people updating from 1.10.0 or older, opening Settings › Desktop Widgets.

- `python3 scripts/test.py --only FeatureIntroductionTests --only FeatureIntroWindowTests --only ActivationPolicyRuleTests` — passed
- `python3 scripts/test.py` — exit 0; 4990 tests: 4921 passed, 69 skipped
- Offscreen renders of the window (`FeatureIntroWindowTests.testSnapshotsOnRequest`, `WALLPAPER_MACHINE_FEATURE_INTRO_SNAPSHOTS`) checked by eye in en, zh-Hans, zh-Hant, ja, ko and pt-BR, light and dark
- Gap: not opened on the desktop; the launch path (window over the panel, Set Up opening Settings › Desktop Widgets, the Dock icon) was not exercised in a running app

## 2026-11-12 — Desktop widget fonts, effects and clock options

Installed font families, italic, letter spacing, line height and case; gradient fill, accent colour, outline, glow, a configurable shadow, a background plate and rotation; style presets; clock leading zero, AM/PM and stacked layout; clock-face dial marks, numbers and ring. Rebased onto the layers and snapping change (05e13ded); the preview's frame, snapping and the Center buttons use the turned box of a rotated widget.

- `python3 scripts/test.py` on the rebased tree — exit 0; 4979 tests: 4911 passed, 68 skipped
- Offscreen renders of each style preset, a stacked clock, an italic installed family, a turned outlined date, numbered and ticked clock faces, an accented calendar and a gradient with glow, drawn by DesktopWidgetView into PNGs by a throwaway test (not committed) and inspected
- Not checked: widgets on a real desktop, over moving wallpapers and across Spaces; snapping a rotated widget by hand

## 2026-11-12 — Desktop widgets: layers list, snapping guides, Center buttons

- python3 scripts/test.py: Python stage passed; native 4906 passed, 0 failed, 68 skipped.
- Targeted: WidgetsSettingsTests, DesktopWidgetSnappingTests, DesktopWidgetTests, DesktopWidgetControllerTests, SettingsSectionsLocalizationTests passed.
- Covered: layer order (add in front, move, refused stale drop, duplicate), window stacking, preview stacking, snap lines and guides, drag snap on the display and Command bypass, Center buttons for a left-aligned text.
- Gap: the panel and the desktop windows were not looked at; drag-and-drop of list rows, the guides' look over real wallpapers and window stacking on a real desktop are unchecked by hand.
- App not rebuilt.

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
