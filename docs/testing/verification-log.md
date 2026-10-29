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

## 2026-10-28 — Updater: public GitHub proxy fallback and resumable downloads

- Change: when GitHub is unreachable the update check and download go through ghfast.top, gh-proxy.com, gh.llkk.cc; downloads resume across sources with Range; installer refuses a copy not newer than the running one; release page opened only on github.com.
- python3 scripts/test.py --only AppUpdateTests: 62 passed.
- python3 scripts/test.py: 4193 passed, 0 failed, 49 skipped.
- Live probe (curl, this Mac's network): the three proxies served the v1.6.5 manifest (200) and a ranged image request (206); ghproxy.net failed TLS. URLSession fetched the manifest through ghfast.top.
- Renderer libraries rebuilt with scripts/build.py --renderer-only (stale after the MetalFX commit); generated bindings unchanged.
- Not checked: an end-to-end update from mainland China without a VPN; no Release build.

## 2026-10-27 — MetalFX upscaling for a lowered render scale (issue 96)

- python3 scripts/check_renderer.py: exit 0, passed; metalfx_upscale_test (5 tests) ran on the GPU and passed: upscaled 50% is closer to the 100% picture than the bilinear stretch, one extra full-size image in the upscaled 50% draw, released on the first drawn frame after it is turned off in a running scene and made again when turned on, a GPU without the scaler (simulated) composes the stretch byte for byte with no extra memory, no change at 100%.
- python3 scripts/check_rust.py: exit 0, passed, including metalfx_upscaling_defaults_off_and_survives_a_restart and the config contract default.
- python3 scripts/build.py --renderer-only: exit 0, bindings regenerated with no change.
- python3 scripts/test.py: exit 0 on the second run, 4186 passed, 0 failed, 49 skipped, after merging main; the first run failed only EnergyUsageMonitorTests.testKernelCountersForThisProcessAdvanceWithGPUWork (a real GPU power reading of 4.6 mW under its 10 mW floor), which passed alone and in the rerun.
- Measured: on a real machine about 50% more power with it on at the same scale, and about 1.1 ms (3024×1964) to 2.6 ms (5K) of extra GPU per frame on an M2 Pro in a headless probe. Not checked: a comparison against Wallpaper Engine (WE has no MetalFX equivalent). Release app not rebuilt.

## 2026-10-27 — Play a collection from Installed and Now Playing's playlist

- Added: playPlaylist action; Play/Shuffle at the end of Installed's view chips and in a collection's context menu; Now Playing names the rotation and gains a Playlist button/popover (Change now, Stop, Settings…).
- python3 scripts/test.py --only PanelPlaylistActionsTests: 18 passed (two new tests: source/order/interval kept, change at once, emptied display filled; refusals change nothing).
- python3 scripts/test.py: 4112 passed, 0 failed, 47 skipped.
- Catalog checks (test_localization_catalogs, test_panel_localization) pass; 7 new strings in all 5 languages.
- Gap: no desktop run; layout of the scope-bar buttons, the bar's fifth control and the popover is not visually checked. App not rebuilt.

## 2026-10-27 — Halloween look

Settings › Appearance gains a Halloween look (Halloween week, the default, October 24 to November 1; Always; Off): its own palettes and pumpkin accent, a jack-o'-lantern in the title-bar mark and the Dock icon, and a Victorian papercut horizon (silhouettes cut from a sheet generated with GPT Image 2.5 on fal.ai) standing on the Now Playing bar, at the top of Appearance and in the empty states.

- `python3 scripts/test.py` — exit 0; Python stage all OK; native 4232: 4185 passed, 0 failed, 47 skipped; 2 runtime warnings without a source location ("should not be called on the main thread"), not traced to this change
- `python3 scripts/brand.py --seasonal` — wrote AppIconHalloween; `scripts/tests/test_brand.py` 8 passed, the Halloween icon render test included
- Offscreen renders (temporary tests drawing `HostedPanel` in a never-shown window, since deleted), two rounds: Library at 1240 and 760 pt, Settings › Appearance, the empty and no-match states, light and dark. Fixed from them: held rows dimmed twice, a weak dark backlight, a moon lost in the light dusk
- Offscreen capture draws the Settings list's selection material black in either appearance; a plain system sidebar list does the same, so it is the capture, not the panel
- Not checked: the real Dock, title bar and window on the desktop, a Release build, and a live midnight change on a running app (covered by a unit test posting `NSCalendarDayChanged`)

## 2026-10-27 — Crowdin open to community translators; add-language import

Issue #106. Crowdin project 941177 made open-join (languageAccessPolicy open, task-based access off) with ru added as a target; crowdin_sync.py gains add-language to write a finished language into the three catalogs; docs, CONTRIBUTING and the three READMEs point translators to Crowdin.

- `python3 scripts/tests/test_crowdin_sync.py`: 26 tests OK (9 new: in-place insertion, all-or-nothing, dry run, registered/unexported language)
- Real catalogs, Crowdin export with ru forced translated: 2226+16+61 units inserted, rest of each catalog unchanged, values exact
- `python3 scripts/crowdin_sync.py add-language ru --dry-run` (live): 2304 strings missing, nothing written; `pull --dry-run`: catalogs match Crowdin
- `python3 scripts/test.py`: exit 0; 4205 tests: 4158 passed, 0 failed, 47 skipped (after `scripts/build.py --renderer-only`; bindings unchanged)
- App not rebuilt

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
