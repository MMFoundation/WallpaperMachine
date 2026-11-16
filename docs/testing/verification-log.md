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

## 2026-11-16 — PR #218: preserve audio rollback after a save failure

- A failed audio activation followed by failed rollback persistence no longer splits the restored draft from the authoritative map or skips live cleanup and operation invalidation.
- Two real-actor regressions failed on unchanged production head 2d436018: audio stayed enabled immediately after rollback-save failure and after a subsequent failed Apply with a late audio report.
- Four new cases cover registration/response and demand failures, original plus persistence/cleanup errors, unchanged on-disk optimistic data, downstream callbacks, fresh/stale Apply tickets and multi-display cleanup.
- The complete focused selection passed 15 tests, retaining healthy initialize-once, ownership-read idempotence, earlier publication races and per-display failure isolation; no existing assertion was weakened.
- python3 scripts/check_rust.py passed: core 436, bridge 990, core integration 20 and shader 1098. Five desktop-window cases excluded; desktop/media/network opt-ins disabled.
- python3 scripts/build.py --renderer-only passed and regenerated unchanged public bridge bindings. No API schema, new UI literal, polling or per-frame work was introduced.
- python3 scripts/test.py passed 718 Python and 5108 native tests, with 70 native skips and two runtime warnings without source locations. An initial Python failure was caused by the harness placing TMPDIR inside the checkout; normal temporary-directory isolation fixed it without changing tests or production code.
- python3 scripts/check_renderer.py passed 3535 tests with seven optional skips; all 12 generated pixel cases and eight projects x two reload cycles passed. The timer benchmark is diagnostic, not energy evidence.
- A focused compile was interrupted with exit 143 during a device disconnect. Source/log/process inspection after reconnect confirmed no surviving run before retry; no interrupted or partial result was counted as passing.
- No Release app, installed-app restart, live capture/player, permission prompt, desktop or energy check. Source fingerprints remained unchanged across the final gates.

## 2026-11-16 — PR #218: resilient capture publication

- PR #218 follow-up: isolate per-display registration errors and verify actual capture ownership before skipping publication repair; no polling or per-frame work.
- The partial-registration regression failed before the fix because the second display retained no owner. Synchronization now attempts every handle and shared demand while preserving the first error.
- The independent-review between-writes schedule was reproduced in the real bridge actor with the worker held after capture registration but before its response write; the descriptor matched while ownership was absent.
- Publication now reads the capture controller through its existing serialized worker lane. Healthy registrations are not repeated; the read does not query permissions or start/restart hardware.
- Nine targeted Rust tests passed, including both new failure regressions, capture-lane read idempotence and the existing saved-audio initializes-once contract.
- `python3 scripts/check_rust.py` passed on the combined source: core 436, bridge 978, integration and shader suites all passed. Five desktop-window cases excluded; the primary-display sanity probe explicitly skipped with no active display; live media/network opt-ins off.
- `python3 scripts/build.py --renderer-only` passed. `python3 scripts/test.py`: 718 Python tests and 5,071 native tests passed, 70 native skips, zero failures; two runtime warnings plus compiler/linker warnings remain.
- `python3 scripts/check_renderer.py`: 3,530 tests passed, seven optional corpus/media skips; all 12 synthetic pixel cases and reload cycles passed. The earlier pipeline was deliberately stopped before the combined correction and is not final-source evidence.
- The combined pipeline survived a device disconnect; surviving processes and exact-source logs were checked before continuing. No duplicate suite was started. Heavy processes were confirmed absent before releasing the shared Mac slot.
- No Release app, live audio/player test, permission prompt, desktop action or energy measurement. Media replay remains driven by host reconciliation; automatic surface recovery without a snapshot waits for the next reconciliation trigger.

## 2026-11-16 — Issue #215: audio startup and media replay

- Issue #215: repair activation-time audio capture and replay system media to a replacement renderer on a retained display handle; no wallpaper-specific conditions or per-frame work.
- Both audio ordering regressions failed before the fix (capture left suspended; response/registration overwritten); the same-handle media replay regression also failed before comparing renderer load IDs.
- Targeted native media tests: 23 passed. Targeted bridge operation/audio/media tests: 168 passed, including the new media-instance consent and presentation test.
- `python3 scripts/check_rust.py` passed: core 436, bridge 975, integration and shader suites all passed. Five desktop-window tests excluded; live media/network opt-ins disabled.
- `python3 scripts/build.py --renderer-only` passed and regenerated Swift/FFI bindings from the changed bridge API.
- `python3 scripts/test.py` ran once as the final routine gate: 718 Python tests across 35 modules and 5,071 native tests passed; 70 native skips, no failures. Four main-thread runtime warnings had no source location; compiler/linker warnings also remain.
- `python3 scripts/check_renderer.py` passed: 3,530 tests, seven optional corpus/media skips; all 12 generated pixel cases and reload cycles passed.
- `we_reference.py capture/render/compare` used Wallpaper Engine frames for the reported item. Static before/after output was unchanged: MAD 32.90/33.68 and off48 25.5%/26.1% versus the two references. Existing scene-image differences remain; muted static captures do not verify live music or capture startup.
- The actual wallpaper rendered synthetic song/artist/cover input with 63 generated spectrum bars, nonzero audio response and zero script errors. Lifecycle regressions verify the host fixes without opening an audio device.
- No Release build, installed-app restart, live player, system audio capture, permission prompt or Mac desktop test. The VM was already running for another task and was returned to that task after capture.

## 2026-11-16 — Preserve native readiness across disabled-source normalization (#193)

- Normalize only disabled source fields consistently in partial-disable and prepared manifests; retain active absent-versus-empty semantics. Update the successful-input cache only after readiness is confirmed.
- Controlled red proof on 3ef3427c production files: both new service regressions failed, exposing a redundant saver publication and a restarted lock-screen wait after UUID recovery. The complete six-file prepared patch was preserved and restored byte-for-byte before fixed-source checks.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests --only LockScreenContentSelectionTests: 98 passed, 0 failed, 0 skipped, covering both disable directions, withheld frames, monitor/cancelled refreshes, original timeout and explicit retry.
- python3 scripts/test.py: all Python modules passed; 5106 native tests passed, 0 failed, 70 opt-in tests skipped; two runtime warnings. No failed-gate retry was needed on the corrected source.
- Native work used the Captain-authorized exclusive Mac slot, released after completion. No renderer/Rust changes, Release build, desktop actions or feature-level energy measurement.

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
