# Audio-responsive wallpapers

Scene wallpapers with authored audio effects and web wallpapers with an audio
listener can react to sound playing on the Mac. This document owns the setting, the
capture and the analysis; how a web page receives the spectrum is in
[Web wallpapers](web-wallpapers.md#audio-response), and the now-playing metadata
feature is separate ([Media integration](media-integration.md)).

## Enabling it

Select the wallpaper, then turn on **General configuration → Audio response**
in the inspector. The setting is saved per wallpaper and also applies to that
wallpaper's mirrored displays.

Capture runs only while a wallpaper with audio response on is presenting (not
paused, covered or asleep) and actually reads the sound: an audio-processing
material or particle emitter, a spectrum shader input, or a script that
registers audio buffers. A subscribed web page on screen also counts. A scene
that reads no audio, and every video wallpaper, never starts capture, even with
the setting on; the effects that would have used it received silence anyway. A
script that starts reading later starts capture then.
Capture stops when the last such wallpaper stops presenting or is removed.
Activation errors are reported rather than silently ignored. If one display fails
capture registration, synchronization still attempts the other displays and updates
shared capture demand before returning the first error.
If an Audio response change fails, rollback restores the previous setting in the
draft and authoritative in-memory configuration, attempts live registration and
demand restoration, and invalidates work prepared with the rejected value. A failed
rollback save does not stop those steps: the original activation error and any persistence
or cleanup errors are returned together. Disk may still contain the attempted
setting until a later save succeeds; restored in-memory state is not a claim that
persistence succeeded.

Applying a wallpaper synchronizes capture again after the new display assignment
is published. A scene can report that it reads audio before its first frame,
while the previous selection is still configured; that early report must not
leave the new wallpaper waiting for an off/on toggle. Display changes and repairs
also restore capture ownership and presentation demand from the published selection.
Publication checks the capture controller's actual registration as well as the
renderer flag: concurrent writes can leave those two values disagreeing. This read
runs only at publication, does not touch audio hardware, and leaves an already
correct registration and healthy tap running without reinitialization.

A subscribed web page owns capture independently of renderer scene handles, so
web-only sessions work and scene cleanup does not stop their audio. Both kinds
of wallpaper share one capture tap; pause and the saved Audio response setting
still gate delivery. A web page the user paused withdraws its own request for
audio until it plays again; the shared poller stops once no page still asks for
audio. Enabling media integration alone does not enable audio response.

## Permission

macOS requests system audio recording permission at capture startup. If access
is denied, grant it in **System Settings → Privacy & Security → Screen &
System Audio Recording**, then retry the switch. Permission advice is shown only
for an authorization failure; a device or service error retains its native diagnostic.

If `AudioDeviceStart` returns `268451843` (`MACH_RCV_TIMED_OUT`), the audio service
did not reply in time. Capture stops and releases that session, then tries one fresh
tap and aggregate device before reporting failure. A timeout can leave I/O started
without an acknowledgement, so cleanup includes stopping it. If cleanup fails, the
resources remain owned and no replacement starts. Other errors, including denied
permission, are not retried this way. Recovery runs on the existing capture worker
and adds no work while capture is healthy. A persistently unresponsive audio service
still produces an error after the retry; the app does not restart the system service.

## What the input is

The input is sound playing in other apps. It is not the microphone, and it is
not the wallpaper's own playback. The wallpaper mute and volume controls stay
independent of audio response.

By default (**Settings → Playback & Power → Audio response → Audio capture source**
set to **All apps**), capture is a CoreAudio process tap created with
`initStereoGlobalTapButExcludeProcesses:`, excluding this app's own process so the
left and right channels of all other system audio are analysed by separate FFTs.
If that initialiser is absent or the created tap reports fewer than two channels,
capture falls back to a mono tap: left and right are then equal, and nothing
reports that as stereo. The spectrum's `stereo` flag describes how the PCM was
submitted, not whether the content happens to differ.

### Per-app capture target

**Audio capture source** can also be pinned to a single application by bundle
identifier (`audio_response_target_app` in `AppConfig`). When a target app is
selected:

- CoreAudio process objects are enumerated via `kAudioHardwarePropertyProcessObjectList`
  and matched case-insensitively by `kAudioProcessPropertyBundleID` for both the
  exact bundle identifier and standard macOS helper bundle suffixes
  (`<target>.helper` and `<target>.helper.*`, covering Chromium browsers such as
  `com.google.Chrome.helper` / `com.google.Chrome.helper.renderer` and Electron
  helper processes), always excluding this app's own PID and CoreAudio process
  object ID. Shared system XPC services such as Safari's `com.apple.WebKit.GPU`
  and `com.apple.WebKit.WebContent` carry a shared WebKit bundle identifier rather
  than the host app's bundle identifier (and are also used by WallpaperMachine's
  own web wallpapers), so they are intentionally not matched by bundle ID; use
  **All apps** when capturing audio from Safari.
- When one or more matching audio processes exist, capture creates a targeted tap
  with `initStereoMixdownOfProcesses:` (falling back to `initMonoMixdownOfProcesses:`
  if stereo is unavailable).
- A CoreAudio HAL property listener on `kAudioHardwarePropertyProcessObjectList`
  (debounced after 200 ms, registered only while capture is wanted and a target app
  is configured, with zero polling) watches for the target app launching, spawning
  matched helper audio processes, or quitting. Unrelated apps starting or quitting
  leave an unchanged target set untouched.
- While the target app is not running or has no audio process yet, capture stays
  cleanly idle (flushing two full 48 kHz analysis windows — 3200 mono zeros — so
  both stereo and mono-fallback taps clear downstream FIFOs and smoothing state
  immediately, with no busy loop and no error banner) and attaches automatically
  as soon as `kAudioHardwarePropertyProcessObjectList` reports a matching process.
- If switching the target app fails while stopping or restarting capture, the
  capture controller rolls the backend's target bundle ID back to the previous
  setting and attempts to restore capture state so the backend and process-list
  watcher stay aligned with configuration.
- Stall monitoring checks `kAudioProcessPropertyIsRunningOutput` on the tapped
  processes instead of the global output device (treating empty or exited target
  process sets as idle), so an idle or just-closed target app does not trigger
  unnecessary tap rebuilds while other apps are playing audio.

## Output device changes

Capture is rebuilt when the default output device changes, for example when
headphones or a USB audio interface are connected or removed. The change is
reported after 300 ms without further changes, so a Bluetooth device that
announces a switch several times produces one rebuild. Only a running tap or its
pending recovery is rebuilt: device changes never start a cleanly stopped tap or
one waiting for its first permission grant. A paused display starts a tap on the
current device when it resumes. A rebuild never asks for permission again. The app
watches for the change only while capture is wanted, from the moment a scene that
reads audio or a web page
starts it until the last one stops or capture is suspended, so a Mac whose wallpapers
never read audio has no watcher and a device switch writes nothing to the log.

If the new tap cannot be started, it is tried again after 0.5, 1 and 1.5
seconds; a newer device change replaces the pending retries, and a tap that has
started in the meantime is left alone. After the last failure the log says the tap
could not be rebuilt, and it starts again at the next scene or demand change; no
alert is shown. These steps are written to the application log with the
`[wallpaper-core audio]` prefix. While the tap is down, the analysis treats the
input as stale after 250 ms and the spectrum falls to zero.

A tap that stops delivering is rebuilt too. A tap can stop calling back without
any device change, for example after sleep or a hiccup of the system audio
service. While a tap runs, the audio worker checks once a second how many times
it has called back. A healthy tap keeps calling back with silence when nothing
plays, so only missing calls count, never quiet samples. After 3 seconds without
a call while the default output device is running, the tap is rebuilt the same
way as for a device change, with the same retries; a device change that arrives
in the meantime replaces them. While the output device is idle no call is expected,
so nothing is rebuilt. At most 3 of these rebuilds happen within a minute: a
fourth stall leaves the tap alone until the next scene or demand change, and the
log says so once. The log also records each stall rebuild and the first call
after one. The check runs only while capture is wanted and a tap is running, so a
paused or suspended display, a stopped tap or a Mac whose wallpapers never read
audio has none, and a rebuild never asks for permission.

Healthy capture and unfinished teardown are tracked separately. A failed callback,
aggregate-device or tap release retains its resources for retry but does not report
usable capture. Disabling demand retries remaining cleanup; reactivation or a rebuild
finishes that cleanup before creating another tap, without repeating successful
release operations. Permission is checked before starting a replacement, and repeated
healthy demand keeps the same tap. A failed suspension restores the previous desired
demand and attempts to restore actual capture; if cleanup prevents that rollback, the
error includes both failures. Removed scenes stay removed, even if teardown fails.
The scene/demand and rebuild retry paths recover capture when cleanup later succeeds.

## What wallpapers receive

Wallpapers are authored against Wallpaper Engine's numbers, so the analysis
follows what its developer and its docs describe and what tones measure on it.
Its exact formula is not published; where this differs, it is an estimate.

- Captured audio is analysed at 48 kHz, 30 spectra a second, each from its own
  33 ms Hann-windowed block. Nothing is decimated without a filter, so treble
  stays in the treble bands.
- The 64 bands are one ~23 Hz FFT bin wide up to about 400 Hz and then widen
  exponentially to about 15 kHz: an octave tone at 42 Hz, 95 Hz, 190 Hz, 380 Hz,
  760 Hz, 1.5 kHz, 3 kHz, 6 kHz and 12 kHz peaks in the band Wallpaper Engine
  shows it in. The 32- and 16-band resolutions cover the same frequencies with
  the energy of the bands they merge.
- A band's value is its level on a dB scale anchored at the configured noise floor
  (default `-48 dB`, configurable from `-72 dB` to `-24 dB`): `0` at or below the
  noise floor, about `1` for a full-scale tone at default `1.00×` sensitivity, and
  occasionally a little above `1`, as Wallpaper Engine documents. Normal music sits
  mostly between `0.1` and `0.3` with peaks towards `1`.
- Optional 30 Hz output tuning (**Settings → Playback & Power → Audio response**)
  adjusts the analyzed spectrum without touching audio hardware or taking locks on
  the audio thread (parameters are stored in relaxed `std::atomic<float>` values
  read once per 30 Hz block):
  - **Sensitivity** (`0.25×`–`4.00×`, default `1.00×`): scales analyzed band levels
    before clamping (at `1.00×` the output is bit-identical to legacy behavior).
  - **Noise floor** (`-72 dB` to `-24 dB`, default `-48 dB`): sets the quiet-signal
    cutoff; lowering it reveals subtler music and raising it gates background hiss.
  - **Smoothing** (`0%`–`90%`, default `0%`): applies exponential temporal smoothing
    (`out = smoothing * prev + (1 - smoothing) * raw`) across the 64-, 32- and
    16-band outputs, resetting cleanly on silent blocks, 250 ms staleness, or stop.
    At `0%` every spectrum stands alone and smoothing stays with the wallpaper,
    matching Wallpaper Engine's default.
- A scene frame reads one spectrum, as Wallpaper Engine's do: the first read of a
  frame takes the newest analysis, and every shader pass, particle emitter or
  operator and script of that frame gets that same one, even when the analysis
  publishes the next spectrum while the frame is drawn
  (`ShaderUpdaterAudio.AFrameReadsOneSpectrumWhateverTheAnalysisPublishesMeanwhile`).
  Turning audio response on or off takes effect with the next frame.

Scenes receive the values as analysed; web pages receive them clamped to 0.0–1.0 (see
[Web wallpapers](web-wallpapers.md#audio-response)).

On an active, unpaused [lock screen or screen saver](lock-screen.md#audio-media-and-the-enabled-state),
Scene and Web wallpapers with audio response enabled that actually read audio
(`owe_scene_wallpaper_set_audio_requirement_callback` or `wallpaperRegisterAudioListener`)
receive the main app's single shared analysis rather than opening a second capture tap.
The main app exports all 224 unclamped bands (`left64`, `right64`, `left32`, `right32`,
`left16`, `right16`) into a 4096-byte `mmap` seqlock file (`audio-spectrum.shm`, never
`msync`'d) at 30 Hz only while the extension reports active demand and displays are awake;
the extension injects all three resolutions into its scene `AudioResponseService` and
delivers the clamped 128-bin view to subscribed web surfaces. Display sleep, system sleep,
user or battery pause, unlock, extension exit or app shutdown close the tap and remove the
shared file immediately.

## Supported effect paths

| Path | Notes |
| --- | --- |
| Shader spectrum effects | Authored audio-reactive shaders |
| Web `wallpaperRegisterAudioListener()` | 64 bands per channel, one shared delivery pump capped at 30 Hz; a cleared spectrum keeps arriving through silence (every poll for 1.5 s, then once a second) so pages that smooth per callback finish decaying ([details](web-wallpapers.md#audio-response)) |
| SceneScript `engine.registerAudioBuffers()` | 16, 32 and 64 bands |
| Particle emitters and operators | Box and sphere emitters, and the `turbulence` and `vortex` operators, with audio frequency, bounds and exponent settings; a scene that has any of them captures audio |

## Non-goals

- Pre-rendered video wallpapers do not gain reactive effects.
- The [lock-screen extension](lock-screen.md) never opens CoreAudio capture itself; it only consumes spectra forwarded from the running main app.

## Verification

Synthetic offscreen checks cover the analysis against tone measurements
(`AudioResponseMonoTest` including tuning defaults parity, sensitivity scaling,
noise-floor gating and exponential smoothing reset on silence; `SpectrumExport128Test`
including full 224-band export/inject round-trips, sub-`1e-4` smoothed tail and
coarse-resolution staleness clearing across 250 ms expiry and resume, and
`owe_audio_set_response_tuning` C ABI clamping/propagation, see
[renderer testing](../testing/renderer.md)),
audio-driven shader color and SceneScript scale. Device-free controller, watcher
and bridge tests cover per-app bundle ID and `<target>.helper*` filtering, prefix
collision and shared WebKit exclusion, self-exclusion, 3200-frame mono silence
flushes, clean idle and re-attach on `kAudioHardwarePropertyProcessObjectList`
transitions, failed target-app switch rollback (`capture`, `capture_controller_tests`,
and `capture_lifecycle_tests`), debounced process-list watcher registration
(`device_watch`), config defaults/clamping/round-trip and live tuning/target
propagation (`config`, `web_audio_media`), web-only capture startup, lock-screen
audio demand during desktop presentation suspension, permission, shared ownership,
suspension and shutdown. `AudioResponseSettingsTests` covers the Swift Settings
model, clamping, non-finite rejection, app chooser validation (including rejecting
this app's own bundle ID), candidate deduplication, zero-I/O cached display-name
lookup (`AudioResponseSourceModel`), case-insensitive picker canonicalization,
narrow-column layout and reset.
`LockScreenLiveFeedTests` and `ScreenSaverWebSurfaceTests` cover the `mmap` seqlock
channel, staleness expiry, inode replacement, sleep/exit teardown and web listener
delivery.
The `api::operation_contract_tests::audio_capture_contract_tests` regressions deliver
audio requirements before the first frame, between capture registration and the
worker's response write, and after the worker registers capture. They check response,
ownership and demand without a toggle, including a failed registration that must not
starve other displays. Capture-lane tests verify that ownership reads leave a healthy
tap running and preserve registration while suspended. The contract tests also cover
failed rollback persistence, downstream audio callbacks, fresh and stale Apply
tickets, and independent registration/demand cleanup errors. These cases use
injected engine failures and an obstructed fixture path, not an audio device.
Display changes, save failure and stale-operation repair are also covered. Startup
regressions inject the native timeout and cover recovery with a fresh session,
persistent failure after one retry, cleanup failures that block replacement, and
non-timeout failures that must not retry. They also cover the
[output device rebuild](#output-device-changes): the debounce, the controller restart,
the retry delays and superseded retries. They also drive the stall watch through the
real I/O callback with an injected clock: silence, an idle output device and
suspension never rebuild, a tap without calls is rebuilt once after 3 seconds and at
most 3 times a minute, a device change supersedes a stall rebuild's retries, and the
worker checks only while a counted tap is wanted. Offscreen WebKit tests cover listener
delivery. Live capture and desktop behavior require a separately authorized manual
check; that includes the CoreAudio listener itself, a real device switch and a tap
that really stops calling back, which no unit test can exercise.
