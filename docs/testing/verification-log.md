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

## 2026-10-23 — Web wallpapers: assigning the property listener is not a delivery

A React page that assigns `wallpaperPropertyListener` while it renders (issue #69) looped on the host script's synchronous replay until React error 301 left it blank. The host script now replays only what the page has not taken in, once after the assigning turn, and once more for a listener a handler assigns during that replay. This Mac cannot link the test host, so the native gate runs in CI on the pull request (#72), as agreed on the issue.

- Offscreen `WKWebView` probe with the app's user scripts (no window, no audio) on the reported page: old script → React error 301, 52 listener assignments, empty `#root`; fixed script → full UI, 3 assignments, the player calls `play()`
- Probe scenarios, old vs fixed: render-time assignment (25+ deliveries and an error vs each value once, one pass per render), replaced listener (whole set vs only changes), late listener with pause (called during the assignment vs once after it), directory replay (resent vs only what is owed), throw-and-reassign (stack overflow vs one call); a handler gained later and a throwing first handler behave as before
- Review follow-up, the host script run in Node, PR head 5293a5af vs fix: a listener assigned during the replay (general properties never delivered vs once), a restaged file that arrives with no handler (lost vs owed to the next listener); throw-and-reassign still one call, partial take-in plus throw-and-reassign one extra pass; synchronous re-render, replaced and late listener unchanged
- `swiftc -typecheck` of the shared web wallpaper sources — exit 0; `swiftc -parse` of the two changed test files — exit 0
- `Tests/Unit/WebWallpaper/` (`WebWallpaperAuthorAPITests`, `WebWallpaperSuspensionTests`) updated and extended; not compiled or run locally
- Native stage of `python3 scripts/test.py` — not run: no Rust or renderer Homebrew packages here, so the test host does not link; left to CI on the pull request. Python script tests not rerun after rebasing onto f2d6862e (no Python change)
- Not compared with Wallpaper Engine's frame (VM not used); not checked on the desktop; no Release build

## 2026-10-21 — Opt-in compiler uniform-layout diagnostics

- python3 scripts/check_rust.py --observer-uniform-layout: ordinary and diagnostic stages passed; normal shader990 and observer shader1001 reported tests,9core exclusions and guarded shader skips retained.
- Actual C callers compiled and ran once per mode from the same owned synthetic request: ordinary reflection, annotation metadata, MSL and stage payloads matched; identities/cache keys differed; physical Boolean, widened matrix and padded-array metadata survived the existing accessor.
- The C smoke restored the ordinary static archive afterward. This observes compiler-origin metadata, not native Metal layout, active variants, bound buffers, draws or image parity.
- Final composed python3 scripts/check_rust.py:2267reported passes (388core/872bridge/17integration/990shader),9core exclusions.
- python3 scripts/build.py --renderer-only: passed with generated bindings preserved; python3 scripts/check_renderer.py: passed,12generated pairs/reload coverage,17asset/corpus skips.
- python3 scripts/test.py:425Python and3930native passed;46native skips. No permission, hardware-audio, desktop, private-corpus or network opt-in.
- Retired57assertion-mapped inherited cases while retaining contributor/Henry islands. Earlier failed consumer source/logs and corrected fixture/contract assumptions remain preserved; no failure was relabeled.
- No Release app build or launch; licensing/rights clearance, current-main reconciliation and native effects acceptance remain separate.

## 2026-10-21 — Independent bridge lifecycle and state units

Bounded independent replacements; existing renderer policy, public APIs and contributor-owned feature islands retained. This is not whole-project licensing clearance.

- python3 scripts/check_rust.py — 2241 reported passes (394 core, 839 bridge, 17 integration, 991 shader); 9 explicit core exclusions and 31 guarded shader skip messages.
- python3 scripts/build.py --renderer-only — passed; bindings regenerated without API changes.
- python3 scripts/check_renderer.py — all registered targets passed; 12 generated pooled/isolated comparisons and 8x2 reload cycles passed; 17 asset/corpus cases skipped.
- Timer contract passed; 42 delivered draws were a diagnostic measurement, not a throughput guarantee. Production scheduling was unchanged.
- python3 scripts/test.py — 425 Python tests and 3930 native tests passed; 46 native tests skipped.
- Standalone compiled consumer — genuine core callback cell and production first-frame dispatcher passed ordered delivery, actual pending-send cancellation/join, owner release, stale callback inertia and replacement without replay.
- Mounted actor/state cases retain real builder, callback, journal and six persistence branches. Natural last-owner actor retention failed before the shared runtime-owner fix; final lifecycle and concurrent-drop cases passed. Earlier failures remain recorded.
- No desktop, hardware audio, private corpus, permission prompts, native complete-assembly proof or Release delivery. Contributor-grant filing and remaining protected code/resources are separate.

## 2026-10-20 — Independent display and activation boundaries

Combined current-tree verification in an owned system-temp checkout based on7fad94eb, serialized under the recovery lock with isolated preferences.

- `python3 scripts/check_rust.py` — exit0;2079 reported passes:394core/677bridge/17integration/991shader;9explicit core exclusions and31guarded shader skip messages remain unverified.
- All22new display and23activation cases pass; retained outer actor/display/presenter/configuration suites remain. Source-only writer calls/results and scoped oracle repairs were independently reviewed.
- `python3 scripts/build.py --renderer-only` — exit0; renderer and generated bindings updated. This is not a Release application build.
- `python3 scripts/check_renderer.py` — exit0; all12generated pooled/isolated pairs match expected pixels,8projects x2reloads succeed;17asset/corpus cases skipped. Timer36contract cases pass;52draw benchmark is diagnostic only.
- `python3 scripts/test.py` — exit0;425Python tests;3930native passed,0failed,46skipped. No desktop, media-hardware, network or private-corpus opt-ins.
- A compiled real API consumer passed isolated persistence/reload, display reconnect, public mirror assignments, raw scene/mirror defaults, lock-screen descriptors and capped-rate survey; its throwaway source was removed from the checkout.
- The first attempt remains failed/blocked history: bridge676pass/1fail on JSON numeric-representation coupling, plus a parent relative-output mistake caught by source inventory. Numeric value/key coverage was retained; logs were preserved byte-for-byte and the corrected run used absolute output paths.
- Project-side reconnect/inheritance, web/native-video/export/rate behavior and accepted render-setting lookup remain; no facade/audio cutover, native display/hardware parity, whole-project independence, licensing clearance or Release delivery is claimed.

## 2026-10-20 — Independent library and options-draft replacement

- `python3 scripts/check_rust.py` — final independent tree exit0:394core,632bridge,17selected core-integration and991shader reported passes; nine core exclusions and31guarded shader skip messages remain.
- All25independent library cases and35independent draft cases passed, with4original project-side draft cases and outer library/actor suites retained. All22old inline library identities passed in a verifier-only diagnostic before their removal; that temporary diagnostic overall retained652bridge passes/2failures.
- The two diagnostic failures were unsupported invalid-byte directory creation (EILSEQ before scanning) and an external incidental error-wording assertion. The filename test now controls only observed OsString names over genuine files/model/metadata; native invalid-byte filesystem support remains unverified. The wording assertion was deleted, preserving error category and unchanged state.
- A seven-case original/replacement real-API comparison matched all encoded input bytes, all640000returned RGBA bytes across four PNG/JPEG/GIF fixtures, and all three typed negative outcomes. The real20byte zero-image GIF was Decoding; injected iterator exhaustion is separately IoError/Other. This is compatibility reference evidence, not an independent mathematical or corpus oracle.
- The first replacement comparison stopped at compiler E0277; an explicit borrow of the existing cropped-view Deref target repaired type binding without allocating a crop buffer. It ran no cases; the later replacement collection matched, and the original successful collection was not repeated.
- A compiled actual scan/filter/cache/model/draft/store consumer passed: owned thumbnail results, pending-versus-immediate persistence, Cancel/Apply, canonical documents, invalid mutation atomicity and selector isolation. Only synthetic owned-temp files were used.
- `python3 scripts/build.py --renderer-only` and `python3 scripts/check_renderer.py` — exit0;1974C++passes/17asset skips; all12generated pooled/isolated pairs and8projects x2reload cycles passed. Timer36cases passed;52draws were collected only as a separate diagnostic.
- `python3 scripts/test.py` — exit0:425Python tests;3930native passes,0failures,46native skips. Raw compiler/runtime warnings remain in the evidence.
- Canonical system-temp staging, isolated preferences, source/tool/binary guards and the common blocking lock/process teardown were used. No private corpus, desktop, live login/audio-hardware/network or new paired observer capture was authorized. Temporary original tests and smoke sources were removed before the final gate.
- No Release application was delivered; GPL-2.0-only/notices remain unchanged. Remaining actor/facade/display/activation, native/parser observations, interfaces and contributor/rights publication work are outside this bounded acceptance.

## 2026-10-20 — Independent display coverage and logging, login, power boundaries

- `python3 scripts/check_rust.py` — exit0:394core,594bridge,17selected core-integration and991shader reported passes; nine core exclusions and 31 guarded shader skip messages remain.
- All48new descriptor/model/pointer cases and31retained cases passed. The first gate retained391core passes/3new-case failures; only M19 configured-destination setup, M32 transitional input routing and P01 unsupported raw-mask expectation were corrected. Production was unchanged.
- Logging/login/power replacements preserve five/eleven/eleven existing domain cases, respectively. New logging coverage uses actual filesystem/state/error outcomes and process-isolated global scenarios, not flush-call counts; login has15new pure-operation cases and power has3new CFString groups.
- A compiled smoke exercised real public logger install/host emission/byte accounting/clear and the exact new pure login module with real public status/error types. It did not call live login services or the live power reader.
- `python3 scripts/build.py --renderer-only` and `python3 scripts/check_renderer.py` — exit0;1974C++passes and17asset/corpus skips. All12generated pooled/isolated pairs matched expected pixels;8projects x2reload cycles passed.
- The36timer contract cases passed;52draws were collected only as a separate diagnostic. No production timer/scheduling changes or historical failure reclassification.
- `python3 scripts/test.py` — exit0:425Python tests and3930native passes,0failures,46native skips. Raw compiler/runtime warnings remain recorded.
- All execution used owned canonical system-temp staging, isolated preferences and the common blocking lock/process teardown. Standard controlled native run-loop tests remained included; no desktop, charger/sleep/wake experiment, audio-hardware, private-corpus or network opt-ins.
- Initial failed candidate/logs and source authoring/review records are preserved. The smoke scaffold was removed before final gates; only newly authored modules were formatted, with ignored nightly-only style options reported by the stable formatter.
- No Release app was built/delivered. This bounded support/test slice does not accept parser observations, remaining protected expression, contributor/interface rights or the GPL-3.0-only cutover.

## 2026-10-20 — Independent paths, render-setting lookup and mesh coverage

- `python3 scripts/check_rust.py` — exit 0: 394 core, 568 bridge, 17 selected core-integration and 991 shader reported passes; nine core exclusions and 31 raw guarded shader skip messages remain (excluding test names that merely contain “skip”).
- All ten independent path cases and ten grouped render-setting cases passed. The compiled real API smoke exercised all three activation consumers for exact-match, physical fallback and unsaved settings using only temporary path-backed metadata; no player, window or device was instantiated.
- The first smoke failed because its expected default pan was incorrectly zero; the corrected consumer uses the existing centered default. Production was unchanged and the original failure is retained.
- `python3 scripts/build.py --renderer-only` — exit 0, followed by `python3 scripts/check_renderer.py` — exit 0: 1974 C++ passes and 17 explicit asset/corpus skips. Mesh coverage is 14 cases: seven new contract cases and seven retained index/particle cases.
- All 12 generated pooled/isolated picture pairs matched expected pixels, and eight projects completed two reload cycles each. No private wallpaper corpus or Wallpaper Engine reference comparison was run.
- All 36 timer contract cases passed; the separate diagnostic measured 52 draws in its actual outer window. The four production timer source/header hashes were unchanged; historical 41<42 failures are not reclassified.
- `python3 scripts/test.py` — exit 0: 425 Python tests; 3930 native passes, zero failures, 46 native skips. Existing compiler/runtime warnings remain recorded in the raw result bundle.
- Gates ran once on the new combined tree under the common blocking lock in canonical system temp, with isolated preferences and no desktop, media-hardware or network opt-ins. Source inventory guards passed.
- Only the two new Rust modules were formatted; the stable formatter reported ignored nightly-only style options. The smoke source was removed from the build tree before final gates.
- This is bounded path/lookup/mesh acceptance, not the parser recovery, whole-project independence or license/rights clearance. No Release application was built or delivered.

## 2026-10-20 — Independent bridge domains and documented timer acceptance

Verification applies to the combined working tree based on6a0c47f5, including the separate alias-safe snapshot repair, not to each intermediate commit in isolation.

- Scope: independently authored bridge configuration/project modules and local tests; owner-approved timer contract gating with diagnostic-only throughput; alias-safe lock-screen asset publication.
- python3 scripts/check_rust.py:1952 reported passes; all25configuration and30project cases observed passing;9core exclusions and16raw guarded shader skips remain unverified.
- Verifier-only compatibility:86unchanged original inline test assertions passed after two test-local declaration bindings; original tests/adapters were removed and independent source restored exactly.
- A separately compiled public-API smoke passed persistence/settings, expression evaluation, pre-narrowing colour refusal, future-schema nonmutation, corruption backup and isolated relative-path handling.
- python3 scripts/build.py --renderer-only passed; generated binding bytes remained unchanged. Standard rustfmt was confined to the replacement domains; nightly-only formatting options produced warnings.
- python3 scripts/check_renderer.py passed:1976passed,0failed,17asset/corpus skips;12generated pooled/isolated pairs matched expected pixels;8projects x2reload cycles exited0. GPU and real-time requirements were not skipped.
- Timer production4-file identities are unchanged. All36timer cases passed; the separate real benchmark reported52draws over1001007750ns as diagnostic data, not a performance gate or improvement claim.
- Isolated HOME exposed a general asset-relative-path bug:49native failures before repair,57targeted lock-screen service passes afterward. Final python3 scripts/test.py:425Python tests;3930native passed,0failed,46skipped.
- Historical41/40timer failures, the temporary legacy compilation failure, fixture-construction failure and native failure remain recorded; successful studies were not rerun merely for cleaner receipts.
- No live wallpaper/desktop/audio/VM, universal visual/performance/energy or legal clearance; no Release application delivery. GPL-2.0-only and third-party notices remain until the actual rights/source cutover.

## 2026-10-19 — Independent Rust core recovery snapshot

The complete engine/display/media snapshot was checked together with the reviewed timer harness. Independent source and semantic reviews precede this record; remaining protected tests/interfaces and licensing sign-off are separate work.

- python3 scripts/check_rust.py — passed: 394 core, 581 bridge, 17 selected integration, 991 shader harness cases (1,983 total).
- Rust coverage gaps: nine explicit native/corpus exclusions and 16 raw shader guarded-path skip messages; the drawable-unavailable background probe is not visual proof.
- python3 scripts/build.py --renderer-only — passed; generated bindings and the frozen source snapshot were unchanged.
- python3 scripts/check_renderer.py — 1,984 passed, nine skipped; 36 timer cases included once. All 12 generated cases matched pooled/isolated pixels; required GPU/realtime checks and reload probe ran.
- python3 scripts/test.py — 417 Python tests passed; native 3,930 passed, zero failed, 46 skipped. Desktop/media/network opt-ins remained disabled.
- All stages ran once, serialized, with unchanged revision/content fingerprints; no retry, weakened assertion or transferred lane verdict. The original display gate remains failed and earlier timer-throughput attribution unresolved.
- Deployment/linking/concurrency warnings and one native main-thread runtime warning remain. Native hardware, visual/Wallpaper Engine parity and performance were not established; the separate 3.3 MB memory delta is not approved.
- Release delivery remains pending the separate parser recovery; no installation, manual app launch, desktop action or VM comparison was performed.

## 2026-10-17 — Third-party notices generator and packaging bundle

- python3 scripts/notices.py on the Debug app: 156 components, 127 with license text, 29 without (19 objc2 crates, block2, dispatch2, kameo, siphasher, 6 uniffi crates: no license file in the published crate); --skip-app 155 components, same 29
- python3 scripts/package.py --check (Debug): preflight passes, bundle unchanged; names the 29 gaps; --require-notices fails on them
- Every scripts/tests/test_*.py run as scripts/test.py does: pass (new test_notices.py, extended test_package.py); no native tests, no build, no desktop
- Gap: Release app not built here, Debug closure used; the 29 texts still need upstream license files in Packaging/notices/

## 2026-10-17 — Shader layer swapped for the clean-room wm-shader

Swap step of the own-code plan (Phase 5, shader): Renderer/Shader replaces upstream/renderer/crates/shader; the engine compiles each program once, for Metal.

- `python3 scripts/check_rust.py` — exit 0; wm-shader 915 unit tests plus the ffi_abi and c_abi targets, core 314, bridge 581; asset-dependent corpus sweeps skip with a printed reason when the shipped shaders are absent
- `python3 scripts/check_renderer.py` — every binary passes, generated cases pixel-equal; FrameTimerTest.ADrawSlightlyLongerThanTheIntervalDoesNotHalveTheRate failed once under load and passed on rerun alone (known flake); first run exposed the engine still asking for the retired analysis target, fixed by compiling once for Metal
- `python3 scripts/test.py` — exit 0; 3976 tests: 3930 passed, 46 skipped, 0 failed
- `python3 scripts/check_licenses.py --enforce` on the Release app — 174 components, 0 Apache-2.0, 0 GPL-3.0 family, 0 unknown, 0 not in LICENSING.md (172 with --skip-app)
- Posters, 67 local scenes, 6 interleaved runs per build against the build before the swap: 38 byte-identical, 29 inside each build's own run-to-run noise (mean absolute difference at most 0.33 of 255), no stable difference
- Shader compile over the 67 scenes 111.7 s to 3.8 s, programs compiled 3771 to 2263; five heaviest scenes load 4.4-8.2 s to 0.5-1.7 s (median of three)

## 2026-10-21 — Packed scene videos use shared decoding

- Tests first: shared_video_session_test --gtest_filter='*Packed*' failed four cases before the fix; the sharing-disabled case already passed. Afterward all 14 shared-session tests passed, including identity isolation, concurrent opens and rate splitting.
- Headless runtime smoke: two real scenes independently parsed a synthetic .tex video, prepared/imported it through Metal, produced matching pixel sums with sharing off/on, shared one decoder session when enabled, split at a different playback rate and released both sessions.
- python3 scripts/check_renderer.py: passed on retry; every registered binary returned zero, all 12 generated pooled/isolated image pairs matched, and reload cycles passed. Initial attempt stopped because a test executable disappeared during shared-build test discovery. Local asset/corpus and energy cases skipped; GPU and realtime checks ran.
- python3 scripts/test.py: passed, 3906 passed and 45 skipped, zero failures. The final renderer run also passed all 23 video-source-input tests after concurrent workspace edits completed.
- Wallpaper Engine comparison not completed: scripts/we_reference.py compare 3326873240 reported missing reference frames; that documented packed-video scene is not installed locally. Visual parity, desktop timing, 4K memory and energy were not measured.
- Shared decoding remains off by default; timeline policy is unchanged. No Release build or app restart.

## 2026-10-20 — Fit with blurred backdrop

Fit with blurred backdrop: a scaling mode (`FIT_BLURRED`, `fit_blurred`, `MatchBlurred`) that
places the picture as Fit and fills the room around it with a blurred, darker copy, on both
renderers, Compatibility video, the lock screen and posters; the native video player keeps black
bars and says so. Fill stays the default. Uncommitted, pending the user's approval of the cost.

- `wallpaper_scaling_test` — 14 passed (layout identical to Fit, copy as centred Fill, bands,
  two-step reduction plan, refused values).
- `metal_scene_draw_smoke --gtest_filter='*ABlurredFit*'` — 2 passed on both renderers, including
  a 1536x1024 picture through the two-step reduction; images 0.23–0.34 MB.
- `playback_gpu_test` — 73 passed, 1 skipped (`WE_TEST_VIDEO` corpus); plain video with and
  without direct presentation, poster equal to the drawable.
- `unchanged_present_test` — 12 passed, 1 skipped (energy probe). The change's first version
  overflowed Compatibility's presentation key (about 20 words plus the fill's 5, capacity 24),
  which stopped repeat skipping in every mode; `APlainVideoPresentsEveryNewFrameAndNothingElse`
  and `TheSkipPresentsTheSameVideoFramesInTheSameOrder` caught it. The key now packs the fill
  into at most 3 words and holds 32, and a new test checks the skip in this mode.
- Cost, headless energy harness, 3–4 alternating 15 s rounds, M3 Max, another app build drawing
  the desktop throughout: GPU time per 60 Hz tick, Fit → this mode: 3840x2160 scene at display
  resolution, Native Metal 5.96 → 6.50 ms at 6880x2880@2 (4112x2658@2 within noise),
  Compatibility 5.81 → 6.11 / 4.90 → 5.35 ms; 4K 30 FPS clip on Compatibility 0.25 → 0.54 /
  0.26 → 0.32 ms; whole GPU +0.1–0.2 W, CPU +~8 mW; images 2.0 / 1.2 / 0.86 MB. Runs of one case
  vary up to 2x, so sub-0.5 ms differences are not resolved. Fit records the same commands as
  before (traced: same 37 passes a frame); the harness's Fit timings old vs new disagreed in sign
  between sets.
- `python3 scripts/check_rust.py` — exit 0, 1,527 passed; asset/corpus tests skipped (no assets).
- `python3 scripts/check_renderer.py` — exit 0, every binary 0 (metal_scene_draw_smoke 157 passed, 2 env-gated skips; AnEffectsSwappedBuffers… passed), 12 generated cases pooled = isolated with expected pixels, reload probe 0.
- `python3 scripts/test.py` — exit 0, 3,905 passed, 0 failed, 45 skipped in 146 s.
- Not checked: any desktop run (no visual check on a real display, Settings menu widened to
  210 pt unseen); shimmer from sparse taps is an estimate; no Wallpaper Engine reference (no such
  mode in Wallpaper Engine, VM expired). App not rebuilt.

## 2026-10-20 — Image layers honour the perspective flag

A media-player scene laid its cover and shadow cards on 3D models under a cursor-turned group; the models drew through the 2D scene's perspective camera and the cards drew flat, so the cover and shadows slid off the models as slabs. Image layers with the perspective flag now draw through that camera too.

- `metal_scene_draw_smoke --gtest_filter=*PerspectiveFlag*` — new case fails with the change removed (30 px flat in all four variants, 44.5 expected), passes with it
- `python3 scripts/check_renderer.py` — exit 0 at load average about 3; 24 asset or environment skips
- `python3 scripts/build.py --renderer-only` — exit 0; bindings unchanged
- `python3 scripts/test.py` — exit 0; 3899 passed, 0 failed, 45 skipped of 3944
- Local media-player scene, 240 frames at 1720x720, cursor centred and in a corner, and with the group turned to fixed angles: cover and vinyl cards stay on the models' faces; untilted the frame is unchanged apart from the cards' perspective magnification
- The one other local scene with a flagged image layer: before and after frames identical (no pixel off by more than 16)
- Not compared with Wallpaper Engine's frame: the Parallels reference VM could not be resumed (activation expired)
- Gap: text layers with the flag still draw flat; no desktop run; the app was not rebuilt for Release

## 2026-10-20 — Cover slots over another layer's picture; effect and keyed-constant script objects

A cover slot whose authored texture is another layer's composite now shows that composite until a cover is published, on both renderers, and property scripts get Wallpaper Engine's thisObject for an effect's visibility and for a keyed shader constant's own timeline. Found on a local music-player wallpaper whose blurred cover background rendered as the clear colour.

- `python3 scripts/check_renderer.py` — exit 0; every registered binary exit 0, the new MetalSceneDraw.ACoverOverAnotherLayersPictureShowsThatPictureUntilACoverArrivesOnBothRenderers, SceneSchema.AnEffectsVisibilityScriptSwitchesTheEffectAndNotItsLayer and .AKeyedConstantsScriptPlaysTheConstantsOwnTimeline included; generated cases pixel-equal pooled and isolated; reload probe 0
- `python3 scripts/build.py --renderer-only` — exit 0; App/Bridge/Generated unchanged
- `python3 scripts/test.py` — exit 0; 3944 tests: 3899 passed, 45 skipped
- The three new tests fail with the fixes reverted: the idle, cleared and first-track cover cases draw nothing on both renderers, a cover published mid-run is never shown without the pass marked as reading a runtime image, the effect's script hides its layer, and the keyed constant stays on its first key
- Headless Native Metal probe of the wallpaper at 1720x720, display resolution, with media events and a published cover: the background is a blurred, darkened copy of the cover; with nothing playing it is the default art blurred and the player shows that art; the 21:9 layout option fills the width; the 16:9 option leaves dark side bars on a 21:9 surface, as authored
- Local library: the 14 effect-visibility scripts in 16 scenes use thisObject only for visible
- Not compared with Wallpaper Engine's own frame: the reference VM is unavailable

## 2026-10-20 — Layer composites carry what their effects made

Fixes an audio-visualizer media player whose bars never moved: its spectrum buffer is a hidden layer 64 wide and 0 high whose composite stayed empty. A card with no area that draws into targets of its own now fills them and draws only there, and a chain's last pass writes into its layer's own composite instead of blending into it.

- `metal_scene_draw_smoke --gtest_filter=*NoAreaFills*` — new case fails with either change removed (empty composite, then colour times 0.25), passes with both
- `python3 scripts/check_renderer.py` — first run exit 1: `UnchangedPresent.APlainVideoPresentsEveryNewFrameAndNothingElse` at load average 108; the case alone passed 3/3 at load 12; `--skip-build` rerun exit 0, 24 asset or environment skips
- `python3 scripts/build.py --renderer-only` — exit 0; bindings unchanged
- `python3 scripts/test.py` — exit 0; 3899 passed, 0 failed, 45 skipped of 3944
- Local audio-visualizer scene, 240 frames at 1720x720 with synthetic noise and the app's media events: the buffer layer's composite went from empty to the accumulated spectrum; the bars on the cover now move with audio; nothing else on the frame changed under the same input
- Not compared with Wallpaper Engine's frame: the Parallels reference VM could not be resumed (activation expired)
- Gap: the scene's blurred cover background still draws as the clear colour in the probe; not investigated further. Gap: no desktop run; the app was not rebuilt for Release

## 2026-10-20 — SceneScript start-up order, init values and sound layers

Fixes a music-player widget that sat misaligned and then faded out. Four general script mechanisms: authored names of layers under generated keys are recorded before any script compiles; every property script runs init before any is told the user properties; what init returns becomes the property's value (same kind only); sound objects are layers scripts list and play.

- `scene_schema_tests` — 5 cases (LayersWithScriptsOfTheirOwnCarryTheirAuthoredNameUnderGeneratedKeys, EveryScriptRunsInitBeforeAnyIsToldTheUserProperties, WhatInitReturnsIsThePropertysValue, ScriptsListSoundLayersInTheScenesOrderAndPlayThem, plus the existing authored-name case) pass; the four new ones fail with the source changes removed
- `python3 scripts/check_renderer.py` — exit 0; generated scenes pixel-equal pooled/isolated, 8 reload cycles clean; 24 asset- or environment-dependent cases skipped
- `python3 scripts/build.py --renderer-only` — exit 0; generated bindings unchanged
- `python3 scripts/test.py` — exit 0; 3899 passed, 0 failed, 45 skipped of 3944
- `metal_scene_draw_smoke` on a local music-player scene, 600 frames at 1920x1080: script errors 1 → 0; the cover moves with the player, the player stays shown at 10 s (it had faded out), the track plays, the drag handle is hidden
- Not compared with Wallpaper Engine's frame: the Parallels reference VM could not be resumed (activation expired)
- Gap: with nothing playing, the first-tick idle media state (empty title) makes the widget's title read "-"; unchanged and unverified against Wallpaper Engine
- Gap: no desktop run; the app was not rebuilt for Release

## 2026-10-20 — Issue #61: height fog, model rotation and blur parity

- Generic height-fog pixel regression failed before the fix and passed afterward; property-selected ambient/skylight pixels and three local-rotation regressions pass.
- Scalar swizzle and nested texture-to-scalar shader regressions compile for SPIR-V and Metal; obsolete duplicate scalar sampling rewrite and source-wording tests removed.
- python3 scripts/check_renderer.py — final exit 0; GPU and real-time checks enabled, all twelve generated pixel comparisons and reload cycles pass. Optional local-corpus checks skipped.
- python3 scripts/check_rust.py with installed SceneAssets — exit 0; core, bridge, integration and shader checks pass. Two unavailable private shader fixtures skipped; desktop/corpus exclusions remain explicit.
- python3 scripts/test.py — Python checks pass; native verdict 3897 passed, 0 failed, 45 skipped.
- scripts/we_reference.py capture/render/compare — Wallpaper Engine in Parallels versus native Metal, 3456x2092 at 8.04 s and 15.26 s, identical assembled preset; work-area mean pixel errors 74.80 -> 1.84 and 64.44 -> 1.99 (0-255).
- Both comparison sheets inspected: shading, animated geometry and blur restored; residual moving-edge offsets and Windows activation watermark remain. Final native runs have no shader compilation, translation, effect-load or SceneScript failures.
- Wallpaper Engine kept muted; VM suspended after capture. Native verification was offscreen; Mac desktop presentation was not exercised. Release app not rebuilt.

## 2026-10-19 — Korean release notes for 1.5.7

- Release-note generation and bundled history now support English, Simplified Chinese and Korean; pre-1.5.7 sections stay unchanged and Korean falls back to English for legacy entries.
- `python3 scripts/tests/test_release_notes.py` — exit 0; 74 tests passed, covering generation, validation, legacy reuse and English-only publication.
- `python3 scripts/test.py --only WhatsNewTests --only AppUpdateTests` — exit 0; 70 passed, no failures or skips.
- The first full gate failed two playback timing assertions; the second failed a live GPU-energy assertion. Their focused reruns passed (70 playback tests, 13 energy tests); no assertions or tests were changed or disabled.
- `python3 scripts/test.py` final retry — exit 0; 361 Python tests, 3897 native passed, 0 failed, 45 opt-in network/media tests skipped.
- Checked documentation links, identical historical changelog sections, the 1.5.6 → 1.5.7 notes range, and absence of 1.5.7 banner files after the requested removal.
- No desktop smoke test, app launch, live Steam/media checks or renderer/Rust checks; visual behavior remains unverified. Release versioning and publication use CI, not hand-edited version files.

## 2026-10-19 — Korean localization (#59)

- Catalog coverage: 2,185 Korean translations across app (2,118), permission/InfoPlist (16), and extension (51) catalogs; existing languages unchanged. Reviewed all 2,146 distinct entries and corrected terminology/context mismatches.
- \`python3 scripts/test.py --only AppLanguageTests\` before implementation — expected failure: Korean system matching and Wallpaper Engine locale mapping were absent.
- Targeted \`scripts/test.py --only …\` localization, settings, properties and Korean offscreen-layout run — exit 0; 76 passed, no skips.
- \`python3 scripts/test.py\` — exit 0; 350 Python tests passed; 3,889 native tests passed, 45 opt-in media/network tests skipped, no failures.
- \`python3 scripts/build.py --swift-only --configuration Release\` — exit 0; app and embedded extension built. All 2,185 compiled Korean strings checked against their source catalogs.
- Changed documentation links resolve; \`git diff --check\` passed. No desktop or visual run, permission prompts, live account checks or renderer comparison; renderer code unchanged.

## 2026-10-19 — Media integration enabled by default

- New wallpapers and configurations without a saved media choice enable integration; saved false/true values, preview isolation and lock-screen disabling are preserved.
- Targeted cargo test --release --locked -p wallpaper-bridge --lib tests::web_audio_media: 30 passed; config::store::tests::media_integration: 1 passed, covering saved-choice round trips.
- python3 scripts/check_rust.py --output artifacts/media-integration-default/rust: exit 0 for core, bridge, core integration and shader checks; 9 desktop/corpus exclusions and 5 missing shader-asset checks remain unverified.
- python3 scripts/check_renderer.py: exit 0; all registered binaries passed, 12 pooled/isolated generated cases matched with no diagnostics, reload cycles passed; external-corpus checks skipped.
- python3 scripts/build.py --renderer-only: exit 0; regenerated Swift bindings from the bridge documentation.
- python3 scripts/test.py --only InspectorFlowTests --only PanelPropertyRowsTests --only PanelWallpaperSettingsTests: 56 passed, 0 failed.
- python3 scripts/test.py: Python script suites passed; native gate 3887 passed, 0 failed, 45 skipped.
- python3 scripts/build.py --configuration Release: exit 0; app built without launching or installing it.
- No live media player, desktop UI, permission prompt or Wallpaper Engine frame comparison was exercised.
