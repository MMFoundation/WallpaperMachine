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

## 2026-11-21 — Installed library sort by Energy use (#251)

- `python3 scripts/test.py --python-only` — exit 0; all 36 Python modules passed (including `test_panel_localization.py`, `test_localization_catalogs.py`, `test_doc_links.py`).
- `xcodebuild -project WallpaperMachine.xcodeproj -scheme WallpaperMachine -configuration Debug -derivedDataPath build -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build-for-testing` — exit 0 (`TEST BUILD SUCCEEDED`, zero warnings in touched files).
- `python3 scripts/test.py --only LibrarySortTests --only InstalledBrowserModelTests --only PanelLibraryRowsTests --only PanelViewStateTests --only InstalledPageRenderTests` — blocked (exit 70): `xcodebuild` failed in this sandbox with `Failed to prevent system sleep during UI testing. Error code: -536870211` (`IOPMAssertionCreateWithName`).
- Native XCTest execution and live UI visual verification of the Energy use sort menu remain to be run outside the sandbox; the Release app was not rebuilt.

## 2026-11-20 — OhMyShot in Settings › About and the Help menu

Settings › About gains More from MMFoundation (OhMyShot's icon, a line about it and Get OhMyShot, which opens www.ohmyshot.org, /zh/ for either Chinese) and Help gains OhMyShot Screenshot Tool. Both appear only on macOS 26 and later, which OhMyShot needs; an older macOS shows neither and Settings search does not find the row.

- `python3 scripts/test.py` (run by the developer in Terminal) — 5148 passed, 0 failed, 70 skipped of 5218; every script test OK
- `ExternalLinkTests.testOhMyShotIsOfferedFromMacOS26OnItsWebsiteInThePanelLanguage` — new, passed
- The agent's shell could not run native tests: `IOPMAssertionCreateWithName` fails there (even `caffeinate`), and `xcodebuild test` needs that assertion; an unsigned `build-for-testing` there succeeded
- System Python 3.9 fails several script tests (no `hashlib.file_digest`); Homebrew's python3 passes them all
- Not checked: how the About row looks in light and dark, and the Help menu on macOS 15; no Release build

## 2026-11-18 — Steam Workshop sign-in from Browse and Settings

- Offscreen Workshop regression: the public list offers sign-in when anonymous, hides it after sign-in and offers it again after sign-out.
- Full gate: python3 scripts/test.py (Homebrew Python 3.15); Python checks passed, native tests: 5,128 passed, 70 skipped, 0 failed.
- No live Steam login or on-desktop visual check; no Release build.

## 2026-11-17 — Panel close releases Discover and pixiv results

- `python3 scripts/test.py --only WorkshopSourceTests --only PixivStoreTests`: 75 passed, including the two new unload/resume tests.
- `python3 scripts/test.py` (Xcode 26.6, macOS 26.6.2): 5113 passed, 2 failed, 72 skipped. The two failures, `DesktopWidgetTests/testADateCanBeWrittenInAnotherCalendarInThatCalendarsOwnWords` ("九月30" for "九月三十") and `WebWallpaperErrorStackTests/testStacksReadAsV8WritesThem`, fail the same way on `main` without this change.
- Debug build by hand: Discover searched and paged a few pages, then the window closed. Footprint 213 MB open, 108 MB closed; `heap` showed 111 `DecodedPanelImage` open and none closed, no `WorkshopItem` arrays or `WorkshopPage` caches closed.
- Before the change, the release app after several close/reopen cycles kept 502 `DecodedPanelImage` (187 MB of CG raster data) and six `PanelController`s after the window closed.
- Each closed window left its `PanelController` behind: `leaks --traceTree` rooted it in the toolbar `Menu` (`AppKitPopUpAdaptor`) host, held by an `NSView` notification block. `ControlPanelWindow.tearDown` now takes the toolbar off before the content; a scripted run of ten identical open, page and close cycles went from one more controller and about 1 MB of live heap per close to none left after any close.
- Not checked: reopening on pixiv and Back after reopening by hand (covered by the unit tests); `check_renderer.py` (no renderer change).

## 2026-11-17 — Resume SteamCMD Workshop downloads after native timeouts

- Replayed issue #228 output with a scripted SteamCMD on a real PTY; the new regression failed before the fix with the misleading ownership/Steam Guard error.
- Added four regressions covering split and unterminated native timeout output, automatic retry, checkpoint recovery, bounded retries and no inferred sign-in.
- python3 scripts/test.py --only DownloaderRetryTests --only DownloaderStorageTests — exit 0; 31 passed before isolating the change from PR #229.
- On main, the first full run timed out in the existing retry-sign-in stall test; its isolated rerun passed (1 passed), with no assertion or timeout changes.
- Final python3 scripts/test.py on main — exit 0; all 36 Python modules passed; 5119 native tests passed, 0 failed, 70 skipped; 3 runtime warnings.
- Real Steam large-file transfer, desktop behavior and Release delivery were not exercised; no renderer or bridge changes.

## 2026-11-16 — Nix release pin and login-path integration

- Nix regression against the original Home Manager module: expected failure; the corrected module passes.
- Linux Nix evaluation, one process per system/check: 6/6 derivations pass across x86_64-linux, aarch64-linux and aarch64-darwin.
- Linux Nix module/package builds: 2/2 pass, including five XML preference profiles and the released DMG hash, unchanged bundle, identifiers, version and arm64 executable.
- Nix formatting: all six files pass. Release-pin Python tests: 12 passed, covering updates, races, retries, immutability and downgrade prevention.
- python3 scripts/test.py: all 36 Python modules passed; native results: 5,106 passed, 1 failed, 70 skipped of 5,177, with two runtime warnings. The UUID-recovery lock-screen deadline test also fails alone; tracked as CHE-2. App and native test sources are unchanged by this task.
- The initial native link failure came from a stale bridge archive. python3 scripts/build.py --renderer-only passed and regenerated byte-identical tracked bindings; the subsequent gate linked successfully.
- Documentation links passed (11 tests); git diff --check passed. actionlint passed with the pre-existing queue: max line omitted from its input because installed actionlint 1.7.12 does not support that key; the workflow itself retains it.
- Not verified: actual Darwin Nix builds/sandbox, Home Manager activation, real login startup or release publication. No Release app build, app installation, desktop run, commit or push.

## 2026-11-15 — Nix package and Home Manager documentation

Documented the release package, named settings and extraSettings, and Home Manager standalone or inside nix-darwin. This update changes documentation only.

- nix flake check --print-build-logs: passed on x86_64-linux; existing package and module check results were reused from the Nix store.
- Parsed all four Nix examples with their external arguments bound. Evaluated the standalone, extraSettings and Home Manager inside nix-darwin examples to their activation or system derivations using the locked inputs. No activation ran.
- nix fmt -- --check flake.nix nix/*.nix: passed.
- python3 scripts/tests/test_doc_links.py: passed, 11 tests.
- Earlier implementation checks evaluated all exported systems and passed all 35 Python test modules. The native test gate stopped at missing XcodeGen on Linux and did not pass. Native tests were not rerun for this documentation update.
- macOS signing, activation, wallpaper playback and extension registration remain unverified. The native app was not rebuilt or launched.

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
