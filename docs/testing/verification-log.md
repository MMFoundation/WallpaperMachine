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

## 2026-10-17 — FFmpeg removed: native video and sound only, no libav* in the app

Four commits (3c55d52b audio, f0e3b270 video, d2c891aa Rust decoder, b6ba0c32 build and packaging) delete every FFmpeg use; nothing was run on a desktop, the lock screen or an audio device.

- `python3 scripts/check_renderer.py` after the video commit — exit 0; no failed test, no nonzero count in report.json; `video_source_input_test` 30, `video_probe_test` 10, `video_decode_pump_test` 13, `metal_video_texture_test` 30, `unchanged_present_test` 7, `metal_scene_draw_smoke` 148, `audio_tests` 66 passed; skipped: the env-gated local-corpus cases (not a pass)
- `video_probe_test` on the local library — 20 video payloads, 20 read from memory, 20 opened and decoded by the native backend, 0 declined, 0 refused (this replaces the FFmpeg A/B: nothing in the local library needed FFmpeg)
- `python3 scripts/check_rust.py` after the Rust commit — exit 0; core 314, bridge 581, shader and integration suites all passed; asset and opt-in skips are unverified coverage
- `python3 scripts/build.py --renderer-only`, then `python3 scripts/test.py` — exit 0; 22 Python suites OK; 3930 passed, 0 failed, 46 skipped of 3976. A first run before the renderer was rebuilt failed at the link on the stale `libwallpaper_bridge.a` (undefined `_av_*`): rebuild the renderer after a change like this
- `python3 scripts/build.py --configuration Release` — built; `otool -L` on the app and the lock-screen extension lists only liblz4, libfreetype and libqjs outside Apple's libraries; no undefined `_av_*`, `_avcodec_*`, `_avformat_*`, `_sws_*` or `_swr_*` symbol in the app executable
- `python3 scripts/check_licenses.py --enforce` on the tree and the Release app — 177 components (175 with --skip-app): 0 Apache-2.0, 0 GPL-3.0 family, 0 unknown, 0 not named in LICENSING.md; a returning libav* library is reported unknown (new tests)
- Gaps: VP8, AV1 without hardware decode, 4:2:2, fragmented MP4 and other containers now refuse with a reason and keep the last picture (covered by native tests, not seen on a desktop); the Homebrew ffmpeg, mwe-ffmpeg and dav1d kegs are still installed on this machine and nothing uses them
