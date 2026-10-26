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

## 2026-10-25 — Brazilian Portuguese (pt-BR) localization

- Added pt-BR (Português, Wallpaper Engine locale pt-br) to AppLanguage.supported; every key of App/Resources/Localizable.xcstrings, InfoPlist.xcstrings and Extension/Localizable.xcstrings is translated, including the menu bar and update window strings.
- Added README.pt-BR.md; README switchers, scripts/update_sponsors.py, supporters.yml and docs list it.
- Tests: AppLanguageTests (pt, pt-BR, pt-PT match pt-BR), SettingsBRenderTests pt-BR layout cases; localization tests accept words Portuguese shares with English (Experimental, min, Spaces…); PanelRootRenderTests accepts Latin script for pt-BR.
- Welcome guide: six language tiles keep each name on one line (tighter spacing, slight shrink) instead of breaking inside a word.
- python3 scripts/test.py (before the rebase): 4106 passed, 5 failed, 49 skipped; the 5 (DisplaysSettingsModelTests x4, InspectorWordingTests) also fail on unmodified main on a Mac whose region is pt_BR (decimal comma).
- Release build installed locally and checked by the contributor in Portuguese.

## 2026-10-25 — Puppet texture channels: weight rows and non-finite weights (PR #93 review)

- Supplements the entry above. python3 scripts/build.py --renderer-only before that entry's test.py run: exit 0 (cargo release build and bindings; the regenerated App/Bridge/Generated matched the committed files).
- g_BlendMap is uploaded as exactly the rows the shader declares: enough for every channel the mesh names, more when the material's BLENDROWCOUNT asks for more; a channel past 255 is not painted. Non-finite weights read as 0.
- New tests: MdlSkeleton.ATextureChannelWeightThatIsNotANumberPaintsNothing and three row cases in MaterialContracts.APuppetsTextureChannelPaintsIntoItsPictureOnlyWhileItsAnimationWeighsItIn; both row cases fail on the earlier sizing.
- python3 scripts/check_renderer.py: exit 0. python3 scripts/build.py --renderer-only: exit 0.
- python3 scripts/test.py: first run failed 4 PanelImageViewTests/PanelImagePipelineTests cases right after the renderer check; they passed alone (11 of 11) and the full rerun passed 4111, 0 failed, 47 skipped. Treated as load-timing flakiness, not investigated.
- Not re-compared with Wallpaper Engine: the changes do not alter output for Swimming Kirby (one channel, one row authored).

## 2026-10-25 — Puppet texture channels (eye blink) painted into the puppet's picture

- Wallpaper Engine 2.8.0.42 probes built from Swimming Kirby (3441873795) assets: animation channel records are numbered by order (leading word ignored); weights mix linearly (0.25/0.5/0.75 measured 0.263/0.505/0.759) and interpolate between frames; a lone layer at blend 0.5 paints in full; a hidden layer or none paints nothing.
- Kirby: one channel, 300 frames at 30 fps looping; blinks fade over frames 101-109 and 201-209 (3.37-3.63 s and 6.70-6.97 s of every 10 s).
- we_reference render of probe 1 after the change: same cells blink as in Wallpaper Engine's two shots; constant cells 0.244/0.493/0.753; phase about one 30 fps frame behind Wallpaper Engine (puppet clock start), not compared closer.
- Kirby compare before,after at Wallpaper Engine's shots (30.03 s, 45.49 s; eyes open in both): mean 7.86/7.86 and 16.51/16.49, unchanged; a render at 33.5 s shows the closed eyes. No Wallpaper Engine frame of Kirby mid-blink was captured; the probe stands in for it.
- New tests: MdlSkeleton.TextureChannelWeightsAreNumberedByRecordOrder, MaterialContracts.APuppetsTextureChannelPaintsIntoItsPictureOnlyWhileItsAnimationWeighsItIn, MetalSceneDraw.APuppetsTextureChannelPaintsItsPictureWhileItsAnimationWeighsItIn; MaterialContracts.APuppetsTextureChannelMeshIsNotDrawnAsPartOfTheModel still passes.
- python3 scripts/check_renderer.py: exit 0. python3 scripts/test.py: 4111 passed, 0 failed, 47 skipped (after python3 scripts/build.py --renderer-only, since the worktree's bridge library predated the committed bindings).
- Not checked: a channel puppet drawn with no effects in a real wallpaper (covered by the Metal test only); several animation layers mixing channels; BLENDROWCOUNT above 1 against Wallpaper Engine.

## 2026-10-25 — Update window review fixes (PR #90)

- python3 scripts/test.py: exit 0; Python stage 25 of 25 modules OK; native 4106 passed, 0 failed, 47 skipped.
- Covers automatic updates gated on an in-place install, the update check waiting while the window is open, the checkbox through an action, and the manifest requiring the release's section first.
- Not run: Release build; live download/install from the window and automatic install on display sleep or lock (manual-smoke App update).

## 2026-10-24 — Update window replaces the update alert and What's New; conventional changelog layout

- python3 scripts/test.py: Python stage all OK (test_release_notes 84, test_update_manifest 7, catalogs and panel localization OK); native 4105 passed, 0 failed, 47 skipped.
- Targeted: AppUpdateTests, AppReleaseHistoryTests, UpdatePromptGateTests, ActivationPolicyRuleTests, ClientPreferencesTests, AboutSettingsTests, UpdatePresentationTests pass.
- Update window drawn offscreen (light and dark) from the converted CHANGELOG.md top sections with sample issue/commit links; matches the requested layout. No window shown on the desktop.
- CHANGELOG.md converted: 39 sections and 1254 bullets kept, no Full changelog lines or old category names left; history validation passes.
- Not run: Release build, a live GitHub check, a real download/install from the window, automatic install on display sleep or lock (manual-smoke App update).
- Gap: model-written history bullets have no issue/commit links (no recorded mapping); links start with the next release cut.

## 2026-10-24 — Keep each visited desktop's wallpaper loaded and paused

Follow-up to PR #77: a display with a different wallpaper for each desktop keeps the wallpapers of visited desktops parked (renderer, bridge, web and video hosts) instead of reloading them on every desktop change; memory pressure and Stop (free memory) let them go.

- `python3 scripts/check_rust.py` — exit 0; core, bridge, core-integration and shader all pass, including the new `engine::actor::space_parking_tests` (9), `tests::space_parking` (3) and `first_frame_tests::a_wallpaper_the_display_keeps_parked_is_not_awaited`
- `python3 scripts/check_renderer.py` — exit 0; corpus and media cases skipped as listed (no local assets)
- `python3 scripts/test.py` — exit 0; 4107 tests: 4060 passed, 47 skipped, after one rerun: the first run on the final code failed `EnergyUsageMonitorTests/testKernelCountersForThisProcessAdvanceWithGPUWork` (3.7 mW against a 10 mW floor, right after the renderer check), which passed alone and in the rerun
- New Swift tests: `WallpaperSpaceParkingTests`, per-window placement and opening windows in `WallpaperSpacePinningTests`, kept clips and pages in `NativeVideoWallpaperHostTests` and `WebWallpaperHostLifecycleTests`, the auditor's kept-window excuse, pressure edges in `MemoryPressureMonitorTests`
- Not checked: no desktop run (no intro on return, the kept frame during a swipe, a shared wallpaper on several desktops, `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces`, the memory held, release under real memory pressure); the Release app was not rebuilt

## 2026-10-23 — Different wallpaper for each desktop: windows kept on their desktop, saved posters, new panel UI

Space mode reworked: wallpaper windows of a display in the mode stay on its current desktop and move hidden on a desktop change; other desktops get their wallpaper's saved poster; Apply sets the current desktop's wallpaper; the switch moved onto the display card and the toolbar menu with a desktop strip and a searchable chooser.

- `python3 scripts/test.py` — first run 1 failure (SettingsSectionsLocalizationTests: "Mission Control"/"Spaces" keywords untranslated), fixed; rerun exit 0: 4083 tests, 4037 passed, 46 skipped
- `python3 scripts/build.py --swift-only --configuration Release` — OK (ad-hoc signed)
- Authorized desktop run, macOS 27.0.1, one display, three desktops: a standalone window probe showed CGSMoveWindowsToManagedSpace moves an own window to the current Space; re-ordering, toggling canJoinAllSpaces and moveToActiveSpace do not; an alpha-0 window stays occlusion-visible and keeps vending drawables
- Live app: Mission Control showed desktop 2 Windows 11 and desktop 3 Plastic Beach (before: every desktop showed the live window); swipes show the destination's poster; warm loads shown 0.4 s (Plastic Beach) and 0.9–1.0 s (Windows 11) after the swipe ends
- Relaunch without visiting: both other desktops and the current one got their own poster within ~3 s
- Panel: card switch, desktop strip, chooser popover and the toolbar's toggle and "· Desktop 1" label rendered as intended
- Gap: ad-hoc test builds ask again for System Audio Recording; an audio-responsive scene's first frame waits for the answer (6.4 s and 180 s stalls seen); a pixiv keychain prompt was denied
- Not checked live: Apply assigning the current desktop (unit-tested), chooser search typing, multiple displays with separate Spaces, web/video on a pinned display, VoiceOver

## 2026-10-24 — Daily active count (DAU/MAU) without an install id

- App: TelemetryActiveCount sends one ping per UTC day to /api/telemetry/active (random per-day ping id, day, version, source, monthFirst); hourly retry with the same ping, next send 0-15 min after UTC midnight; no count with WALLPAPER_MACHINE_HOME or a defaults suite.
- python3 scripts/test.py --only TelemetryActiveCountTests --only TelemetryClientTests --only TelemetryServiceTests: 18 passed, 0 failed.
- python3 scripts/test.py (full gate, worktree): Python script tests OK; native 4062 passed, 0 failed, 47 skipped; 1 runtime warning (main-thread call), not traced to this change and not baselined.
- Website (separate repo, branch feat/telemetry-active-count): npm run typecheck OK; local wrangler dev on a scratch D1 with migration 0002: retries (same and lowercase ping) counted once, a day-behind clock kept its day, a far-off clock took the arrival day, bad schema/ping/day/agent 400, cron prune kept 400-day totals and 2-day pings.
- Dashboard DAU/MAU SQL run on the scratch D1 gave the expected sums; the page's new section was not viewed in a browser (owner sign-in needed).
- Not done: no D1 remote migration, no Worker deploy, no app Release build, no desktop run.

## 2026-10-24 — Library location: move library and downloads to an external drive

- python3 scripts/test.py: passed (Python stage OK; native 4051 passed, 0 failed, 47 skipped).
- New: StorageMoveServiceTests, StorageCopierTests, StorageLocationTests, DownloaderStorageTests, WallpaperBackupTests moved-library round trip, PanelStorageActionsTests move actions.
- Another disk is simulated with a fake StorageVolumeInspecting; no real external drive, ExFAT disk or eject was exercised.
- Not checked: Settings › Storage rows and the Wallpaper Library Unavailable window visually, the removable-volume privacy prompt, a live Steam download to a moved library.
- Renderer built in this worktree with scripts/build.py --renderer-only; bindings unchanged. App not rebuilt as Release.

## 2026-10-24 — Desktop posters kept until the wallpaper changes (issue 79)

macOS 26+ WallpaperAgent keeps a full-size bitmap of every desktop picture file and never deletes it; animated wallpapers made every poster retake a new file. Snapshots that change no display, Space changes, wakes and resumes now keep a settled poster, and a frame nobody asked for never replaces one.

- `python3 scripts/test.py --only DesktopWallpaperTests` — 77 passed; the new hours-of-activity test failed (13 captures instead of 3) with the old two-minute expiry put back temporarily
- `python3 scripts/test.py` — exit 0; 4070 tests: 4023 passed, 47 opt-in skipped; Python script tests passed; 1 runtime warning (main-thread call) from another class, not raised by DesktopWallpaperTests
- Not verified: WallpaperAgent's cache on a real Mac (another app's container, not read), real Mission Control thumbnails, `AppDelegate.desktopPosterLayout` (wiring, no unit test); app not rebuilt
- Space-selection mode still takes posters on every Space visit that switches the wallpaper; not changed here
