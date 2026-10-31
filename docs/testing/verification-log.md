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

## 2026-10-31 — WE 2.8 parity rebased onto main 1.6.6 (PR #137)

- Merged origin/main (53 commits) into the parity branch and rebuilt it as eight domain commits on main; the final commit's tree is the gated one.
- Overlaps kept this branch's WE-derived code (script ModelData, particle script controls, puppet bones and layers, SKINNING_ALPHA gate, cursor localPosition, colour emoji); main's tests kept and adapted, four dropped where they contradict the native (listed in the PR).
- Kept from main: texture channels, MetalFX, capability probe and missing files, level clipping (plus volume textures), click on release, live material constants, compose-layer script children, poster generator (plus colour options), pt-BR (new strings translated).
- WE loader 0x140261880 read again: the MDLA version-3 block is texture channels (count, then per channel a skipped word and frames + 1 floats).
- check_rust.py OK; build.py --renderer-only OK; check_renderer.py 3,390 passed, 0 failed, 7 skipped; test.py 4,252 passed, 0 failed, 52 skipped.
- Not run after the rebase: 17-scene sweep, Release build, desktop run.

## 2026-10-31 — WE 2.8.0.42 parity round 6: steady rope smoothing, 3D perspective layers, sorting toggle, HDR and energy on the desktop

- Steady uvsmoothing: WE probe rope-uv-v5 (5 variants) within ~0.01 of WE on shot 0; the 8 Hz smoothed rope stays off (+0.014 against WE's -0.110) and shot 1 has a clock offset (12.198 s against 12.292 s).
- Perspective layers in 3D: six WE camera probes (eye, fov 30/50, centre) give the same MVP x/y/w columns; the z column differs and was not compared. PerspectiveImage 6/6.
- Out-of-plane IK ropes: WE controls with the rope tilted/yawed 60 degrees agree with WE as well as the untilted control does (whole-frame correlation 0.82/0.71 against 0.58); no local puppet has a branched rope.
- Sorting runtime toggle: WE probes sort-runtime-off-v1/on-v1 match 36/36 samples, 4 cells change between the states; WE stayed up (no DXGI loss).
- HDR: built-in XDR (headroom 8), scene 3662790108. Display HDR peaks at about 53 against Ultra's 1.0, on 0.035 % of pixels, same median. Brightness as seen by eye was not compared with WE.
- Energy (coalition, no root, VM suspended): scene 3615154110, three alternating new/old pairs at ~60 fps, difference under ~0.5 W GPU (upper bound). Display HDR 29.4 W against Ultra 25.1 W on 3662790108. No powermetrics.
- check_renderer: 3,322 passed, 0 failed, 7 skipped; build.py --renderer-only OK; test.py 4,150 passed, 0 failed, 50 skipped; Release build OK.
- 17-scene sweep against the previous final: 34/34 frames rendered and within 0.3 mean, except 3280146735-0, whose date text changes with the calendar day (calendar caveat), and 3665954520-1 (+0.24).

## 2026-10-31 — WE parity: last rope branches, zero-direction box, 3D far plane, final sweep

- Steady uvsmoothing rope (0x140230A42: length steady-1, start saturate(first age / birth spacing) - 1) and scrolling rope trails (TRAILSCROLLALPHA with fade combos, g_RenderVar0.x/.w per 0x1402366F0) follow WE; tests added.
- boxrandom with directions 0 0 0: WE divides velocity by the zero spread length (0x140238B3C), so the particles are NaN and never drawn (probes bisect-clock vs bisect-clock-dir); ported; 38 test fixtures that used zero directions for 'no spread' now use 1 1 1 with distancemax 0.
- WE probe far-plane-v1: cards beyond farz are clipped and the near pair occludes identically in WE and here; WE's reversed-Z clip layout is therefore not visible to ordinary materials and was not ported.
- check_renderer.py 3,321 passed, 0 failed, 7 skipped; build.py --renderer-only OK; test.py 4,150 passed, 0 failed, 50 skipped.
- Plan V3 17-scene comparison against the Phase 0 baseline: 34/34 frames, 5 better, 0 worse; final equals the previous sweep on all 34 frames.

## 2026-10-31 — WE parity: rope texture rules from a WE UV probe

- WE probe rope-uv-v3/v4 (parabola ropes whose stock fragment, overridden in the project, writes its texture coordinate): rope length = points / uvscale; scrolling = first emitter rate x average lifetime (lifetime override included) - 1, rate capped by the frame-rate cap while filling, offset by deaths; uvsmoothing plain until steady.
- After the change every non-steady cell agrees with WE within 0.01 of v (scrolling was 0.55 against 0.93; uvscale 2 end -0.98 against -1.05); subdivided rope silhouettes match WE (0.995-0.998). Steady-state uvsmoothing offset and scrolling rope trails remain this port's.
- Compile fallback now keeps a geometry stage when only the fragment fails, as WE replaces only the failing stage. boxrandom with directions 0 0 0 draws nothing in WE (documented, not changed).
- check_renderer.py 3,318 passed, 0 failed, 7 skipped; build.py --renderer-only OK; test.py 4,150 passed, 0 failed, 50 skipped; 17-scene sweep 33/34 unchanged (3280146735-1 clock text).

## 2026-10-31 — WE parity: rope strips per pair, blended operator kernels

- Ropes with a geometry stage now take WE's one record per pair (0x1402308A0) and are subdivided by the stage (TRAILSUBDIVISION, 4 + 2s strip vertices, D3D strip order); the vertex-only fallback keeps CPU pieces. Trail probe unchanged (straight, untextured: curved ribbons not compared); heavy-rope probe at subdivision 32: no cost beyond noise.
- The blended operator kernels (opcodes 28-40) decompile after reading 0x14023FBC0's jump table to 40 entries: remap/inherit lerp old to new by the window weight (as implemented); angularmovement now weighs its turn and clamps drag before weighing; controlpointattract weighs the pull after the flag-2 cap.
- Rope texture-length rules decoded (flags, 1/uvscale, scroll/smoothing lengths) but not changed: +444/+448 field identities need a runtime probe.
- check_renderer.py 3,316 passed, 0 failed, 7 skipped; build.py --renderer-only OK; test.py 4,150 passed, 0 failed, 50 skipped; 17-scene sweep 33/34 unchanged, 3280146735-1 clock text.

## 2026-10-31 — WE parity: culling, rope-trail recording clock, event-death and rope geometry follow-up

- WE 2.8.0.42 probe ordinary-cull-v1 (2D canvas): WE culls `cullmode normal` without depth and keeps the authored card; ours now agrees on 8/8 tiles (cards counter-clockwise, cull mode in every pass, no reflection-pass winding flip).
- reflection-cull-v7 now agrees on 24/24 samples including the ordinary clip pair; the reflected world pair is unchanged (31,119 pixels, same bounds).
- Rope-trail recording follows WE's countdown in 0x1402308A0 (first frame due, whole-frame periods, no prewarm recording, oldest point kept): trail probe spans 75.0/58.8 px -> 81.2-84.0/67.9-70.7 px against WE 80.0-82.8/69.4.
- `check_renderer.py` 3,314 passed, 0 failed, 7 skipped; `build.py --renderer-only` OK; `test.py` 4,150 passed, 0 failed, 50 skipped.
- 17-scene sweep after the change: 33/34 frames equal to the previous sweep within 0.01 (including the five scenes with culling materials), 3280146735-1 improved (clock text).
- Not done: perspective:true layers in 3D scenes (WE pulls the view back ~1990 units with a 2000x zoom) and WE's infinite reversed-Z projection (clip z = near); Release build; desktop run.

## 2026-10-30 — WE parity: rope geometry stage, event-death children, createLayer angles, planar reflection

- Rope materials with a `.geom` draw through the lowered geometry stage (four strip vertices a piece): WE trail probe ribbon width 19.9 px vs WE 19.6-19.9 and centre within 0.2 px; trail length unchanged (about 75 vs 83 px).
- Shader `metal_compile.rs` translates and system-compiles the shipped rope program with its geometry stage for 384 combinations; a 264k-piece offscreen rope probe showed no cost beyond run-to-run noise (upper bound about 0.3 ms/frame).
- `eventdeath` children keep emitting after the death that made them (native 0x140236CD0): parent-copy probe 64/64 particle and control-point samples, including the eight event-death samples that were blank.
- `createLayer` angles are scene-file radians: WE model-matrix readback matches on all four panels; the 3D perspective MVP z column remains different.
- Planar reflection integrated after cost approval; particle control-point probes G 128/128 and I 144/144.
- `check_rust.py` passed; `check_renderer.py` 3,311 passed, 0 failed, 7 skipped; `build.py --renderer-only` OK; `test.py` 4,150 passed, 0 failed, 50 skipped (first run blocked by File Provider xattrs on `build/`, cleared per docs/build.md).
- 17-scene sweep, paced: 34/34 frames, no visible rendering regression; 2998757800 and 3662790108 improved; metric increases are calendar/clock text (render date 10-30 vs captures 10-25) or stochastic particles.
- Not done: Release build, desktop run, GPU-side rope subdivision, 64-segment trail length, 3D ModelData projection.

## 2026-10-30 — Scene parity: shader contracts, HDR framing, particle frames and volumetrics

- Integrated shader R8 author validation, puppet axis links, HDR pre-bloom framing, parent/world particle frames, volumetric lights, and the shared-depth state transition repair; planar reflection remains a separately verified private candidate pending resource-cost approval.
- python3 scripts/check_rust.py — final exit 0: 2,418 passed; five explicitly excluded desktop-window tests. The first-frame scene fixture now uses the WE matrix convention.
- python3 scripts/check_renderer.py, followed by failed-gate retries (final --skip-build with unchanged C++ inputs) — final exit 0: 3,244 passed, seven explicit asset/corpus/energy/clip skips; all 12 generated pooled/isolated pictures and 16 reloads passed with zero generated shader diagnostics.
- python3 scripts/build.py --renderer-only — exit 0; renderer and generated Swift bindings updated. The mode now prints its completion verdict. No Release app build or desktop run.
- python3 scripts/test.py — final exit 0: 464 Python tests; native 4,150 passed, zero failed, 50 skipped. The first full run failed one backup keep-existing case; it was not stably reproduced. Snapshot/archive/restore assertions were strengthened without a production fix, sleep, or test retry.
- Three native runtime warnings were attributed to passing WebMFilteredVideoSinkTests.testDecoderFailureIsReportedInsteadOfSendingAnUnfilteredPacket, VideoFormatSupportTests.testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne, and WebMPlayerTests.testAClipMarkedAsTurnedIsShownWithItsAxesExchanged; their responsible API was not identified.
- WE comparisons: particle G/H/I effective CP/world samples agree within one encoded channel; volume inside point ROI is exact and spot maximum difference is one. Caster-on ROI MAE improved 27.2271→0.34573 (point) and 3.67252→0.17549 (spot); shadow-edge differences remain.
- Private reflection candidate: 91 CPU and 27 GPU checks passed; combined reflection/volume/HDR candidate passed 71 CPU and 44 distinct GPU checks with Metal validation. Core reflection ROIs and explicit null/forward/winding controls match WE; this candidate is not enabled in MAIN.
- Physical EDR appearance, live desktop/audio/network options, the final 17-scene sweep and remaining advanced plan contracts are not verified by this milestone. Ordinary direct clip-space culling differs from WE and is recorded in renderer limitations.

## 2026-10-30 — Keyed shader constant played by a script without update

A cover cross-fade (blend amount keyed 1 to 0, start-paused, played by a mediaThumbnailChanged handler that only calls thisObject.getAnimation().play()) stayed on its first key, so the previous-cover slot covered the current cover. The handler-only script was never started; it now runs on the clock its constant's timeline plays on.

- Wallpaper Engine 2.8.0.42 probe (generated opacity cells, scene version 4, two shots): no script 255 / 255 before / 255 after; init plays with no update 0 / 255 / 0; init plays with update(value) 0 / 128 / 128 (not fixed, documented in renderer.md); static 0.25 64 / 64 / 64; keys not paused 0 / 0 / 0
- `we_reference.py compare` on the probe: before mean 21.73, off48 11.7%, corr 0.634; after mean 7.69, off48 6.2%, corr 0.883 (the update(value) cell and the watermark remain)
- Workshop 3280146735 in the poster harness with `WE_TEST_MEDIA_ARTWORK=64x64:e01010` and playing/thumbnail events: cover centre (30,30,30) before, (224,16,16) after, at 8 s and 15 s
- Not compared: that wallpaper against Wallpaper Engine (the VM has no player, so its card hides on PLAYBACK_STOPPED), and a live Apple Music cover in the app (needs a desktop run)
- Cost: about 0.36 µs per tick per such constant (one update-less script evaluation, as other handler-only scripts)
- `scenescript_behavior_test --gtest_filter=ScriptKeyedSettingObject.*`: 5 passed; both new tests failed before the fix
- `python3 scripts/check_renderer.py` — exit 0; local-corpus tests skipped (no corpus environment)
- `python3 scripts/test.py` — 4211 passed, 0 failed, 49 skipped (after clearing build-product xattrs and rebuilding a stale `libwallpaper_bridge.a` with `build.py --renderer-only`)

## 2026-10-29 — Keep SteamCMD current, SteamCMD canary, hotfix releases

- python3 scripts/test.py on the branch rebased onto e20f6223: 4211 passed, 0 failed, 49 skipped (Python, XcodeGen, native).
- New tests: SteamCMDSetupTests (outdated managed copy replaced; current copy left; daily and 10-minute due rules; clock set back; unreadable manifest and failed update quiet with the working copy kept; approval-held update shown; located copy never touched).
- DownloaderFailureOutputTests (silent exit before sign-in flagged, redacted tail kept; Steam-reported failure not flagged), WorkshopStoreTests (one retry after SteamCMD changed, none when unchanged), DiagnosticsBundleTests (steamcmd-failures.txt redacted, absent without a note).
- test_steamcmd_canary.py (manifest with Valve's kvsign blocks, checksums, zip paths and links, issue decisions); test_bump_version.py HotfixTests (patch-only, newer than every tag, tagged commits not released again).
- Live: steamcmd_canary.py --version-only read Valve's manifest 1792617903 (2026-10-21); real packages downloaded, verified, unpacked; Valve signature (team MXGJJ98X76) verified. actionlint clean on version.yml, checks.yml, steamcmd-canary.yml.
- Hotfix rehearsal in a scratch clone: v1.6.5 -> 1.6.6 on hotfix/1.6.5, minor refused; merge of v1.6.6 into main clean; next notes start at v1.6.6. GitHub rules for main and hotfix/** are empty, so Actions can push both.
- Reviewed with son-loop: 1 round, Sonnet 5.5 (high), approved; four nits declined.
- Skipped: running the downloaded SteamCMD locally (not permitted); not exercised: an in-app update against Valve, a real-account sign-in, the workflows on GitHub; the app was not rebuilt.
