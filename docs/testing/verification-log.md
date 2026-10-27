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

## 2026-10-26 — MetalFX upscaling for a lowered render scale (issue 96)

- python3 scripts/check_renderer.py: exit 0, passed; metalfx_upscale_test (4 tests) ran on the GPU and passed: upscaled 50% is closer to the 100% picture than the bilinear stretch, one extra full-size image in the upscaled 50% draw, released on the first drawn frame after it is turned off in a running scene and made again when turned on, no change at 100%.
- python3 scripts/check_rust.py: exit 0, passed, including metalfx_upscaling_defaults_off_and_survives_a_restart and the config contract default.
- python3 scripts/build.py --renderer-only: exit 0, bindings regenerated with no change.
- python3 scripts/test.py: exit 0, 4175 passed, 0 failed, 47 skipped (panel switch round trip, reset, energy-restart coverage), after merging main.
- Measured: on a real machine about 50% more power with it on at the same scale, and about 1.1 ms (3024×1964) to 2.6 ms (5K) of extra GPU per frame on an M2 Pro in a headless probe. Not checked: a comparison against Wallpaper Engine (WE has no MetalFX equivalent). Release app not rebuilt.

## 2026-10-25 — Scene script APIs, puppet bone opacity, colour emoji, Workshop presets, Steam subscriptions and comments

Particle-layer script API, camera transforms, setParent with adjustTransforms, bone getters, single-play and created animation layers, per-bone puppet opacity (g_BonesAlpha), colour emoji from Apple Color Emoji, Workshop preset marks, a preset base's name, size and free-space check, base updates reaching installed presets, subscribe/unsubscribe with subscribed marks, and read-only comments. Engine tests were run failing before each fix except the particle API, built together with its tests. C10 (transform effect intermediate passes), C12 (reflections, declined) and D13/D16 (SteamCMD session reuse and delta updates) were not done.

- `python3 scripts/test.py` — exit 0; 4168 tests: 4121 passed, 47 skipped
- `python3 scripts/check_renderer.py` — exit 0; corpus-dependent cases skipped: no local corpus
- Not compared with Wallpaper Engine frames: this Mac has no Parallels VM, Wallpaper Engine assets or local corpus
- Subscribe, unsubscribe and comments pinned against fixtures only: steamcommunity.com is not reachable from this Mac
- D13/D16 not attempted: no SteamCMD setup or saved Steam sign-in here; C10 left for a reference capture, since it changes every effect pass
- App not rebuilt; nothing checked on a live desktop

## 2026-10-25 — Audio exclusions, update signatures, click on release, material reads

System feedback sounds no longer count as another app playing, in-app updates must carry an intact signature that meets the release requirement when replacing a release, scene scripts get cursorClick on release over the pressed layer, and scripts read a material constant's authored or default value. Each was written test first; nine existing engine tests that treated a lone press as a click now tap. A Window menu written alongside was dropped in favour of the one main added in the meantime, so `ApplicationMenuTests` below no longer exists.

- `python3 scripts/test.py --only OtherAudioMonitorTests --only ApplicationMenuTests --only AppUpdateTests` — 68 passed
- `python3 scripts/test.py` — exit 0; 4162 tests: 4115 passed, 47 skipped; Swift linked the renderer library built before the engine changes, which check_renderer covers
- `python3 scripts/check_renderer.py` — exit 0 after fixing `ClickScripts.OnlyTheHitOneOfThreeSameNamedLayersPlaysItsOwnSound` (first run failed it); corpus-dependent cases skipped: no local corpus
- Update signature logic checked by hand against the published 1.6.3 disk image: release requirement met, strict deep check 0.17 s, a wrong certificate hash refused (-67050)
- Not compared with Wallpaper Engine frames (no VM run); the order of cursorUp before cursorClick was not read from Wallpaper Engine
- Not checked: the Window menu and hiding on a live desktop, the audio exclusions against real Siri or volume sounds; app not rebuilt

## 2026-10-27 — Crowdin integration: GitHub and Crowdin setup

Follows the Crowdin integration entry; those entry's open items were set up afterwards.

- `gh secret list` — CROWDIN_PERSONAL_TOKEN present on the repository (value never read back); the same token read and wrote to Crowdin with no saved CLI identity (`crowdin status`, unchanged `push`)
- `gh api .../actions/permissions/workflow` — organization and repository both read back `can_approve_pull_request_reviews: true`, `default_workflow_permissions: read`, so Actions can open the translation pull request
- `python3 scripts/crowdin_sync.py push --overwrite` — ja, ko, pt-BR, zh-CN, zh-TW at 100% translated and 100% approved; `pull --dry-run` afterwards: the catalogs already match Crowdin
- Bot commits and pull requests are titled `chore(localization): update translations from Crowdin`, so they stay out of the release notes
- Not verified: .github/workflows/crowdin.yml has not run on GitHub (it is not on main yet), so the push, pull and pull-request steps are untested there

## 2026-10-27 — Crowdin integration

Tooling and CI change: crowdin.yml, scripts/crowdin_sync.py (push/pull), scripts/lib/localization.py, .github/workflows/crowdin.yml and docs/localization.md#crowdin. No app code changed, so no app build.

- `python3 scripts/test.py --python-only` — exit 0; 27 test files OK, incl. test_crowdin_sync.py (17 tests), test_localization_catalogs.py (8) and test_doc_links.py (11)
- First push to the Crowdin project (941177): 3 catalogs; ja, ko, pt-BR, zh-CN, zh-TW 100% translated, 0% approved; `pull --dry-run` on the real export: catalogs already match
- Real export tags confirmed: zh-Hans, zh-Hant, ja, ko, pt-BR (pt-PT exports as `pt`, ignored); untranslated units export as `new` and are skipped
- End to end on a throwaway Crowdin branch: 3 translator edits flowed into 3 of 366 cells with the one-line layout kept; a %@ to %d edit was refused
- Conflict probes on throwaway branches: an approved translation survives a plain re-push; unapproved ones do not outrank a newer value; --auto-approve-imported overwrites (documented in docs/localization.md#crowdin)
- Not verified: the workflow has never run on GitHub and was only parsed as YAML (no actionlint); PR creation (the repo setting "Allow GitHub Actions to create and approve pull requests" is off); the CROWDIN_PERSONAL_TOKEN secret is not set

## 2026-10-25 — Updates, web, downloads, Workshop, scene and panel improvements

Update signature check, http in web content, page errors in the log, frame-confirmed switch hold, saved pause, download queue order and batch retry, Steam favorites, timeline mirror mode, CursorEvent.localPosition, tile zoom and Help menu, doc link check.

- `python3 scripts/test.py` — exit 0; Python stage 26 modules OK (`test_doc_links` included); native 4174 tests: 4127 passed, 0 failed, 47 skipped
- `python3 scripts/check_rust.py` — exit 0; bridge 897 passed (7 new in `tests::saved_pause`), core 413 passed, shader and core-integration OK; desktop/media/network opt-ins off
- `python3 scripts/check_renderer.py` — exit 0 on an idle machine; an earlier run beside Xcode tests failed two `metal_scene_draw_smoke` direct-video timing cases that pass alone
- Updater requirement checked against the published 1.6.3 image: `codesign -R` and `SecStaticCodeCheckValidity` accept it, refuse it under another certificate root
- Steam favorites page layout and `sortmethod` values read off a public profile's favorites page; a signed-in subscriptions page was not checked
- Not compared with Wallpaper Engine frames (no VM run): mirror end-frame behaviour, `localPosition` y direction
- Not run on a desktop: the frame-confirmed release of the switch hold, http loads, the View and Help menus, the fourth Discover tab's fit

## 2026-10-25 — Scene capability probe, remembered Native Metal verdicts, mirror audio and issue-report details

- `python3 scripts/test.py`: 4124 passed, 0 failed, 47 skipped (opt-in layers); includes `SceneDrawVerdictsTests`, the new `WallpaperCompatibilityTests`, `PanelLibraryActionsTests` (Apply question), `PanelLibraryStateTests` (changed properties, missing files), `NativeVideoWallpaperHostTests` and `MirrorAudioOwnershipTests`.
- `python3 scripts/check_rust.py`: passed, with `tests::scene_capability` and the mirror audio-source assertion in `native_video_routing`; desktop/media/network opt-ins off.
- `python3 scripts/check_renderer.py`: passed, with the new `scene_capability_probe_test` (4 tests) and the loader now on `Scene/SceneProjectLoading`; local-corpus cases skipped (no Wallpaper Engine assets or library on this Mac).
- Gap: the probe's missing-file list was checked only on synthetic scenes, so false positives on real Workshop scenes are unmeasured.
- Gap: no desktop run: the card, the Apply question, mirrored-video sound hand-off and real two-display behaviour are unverified on screen.
- Not compared with Wallpaper Engine frames: no renderer output changed.
- Not done: one shared player per mirror group (double decode remains), pending an authorized two-display measurement.

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
