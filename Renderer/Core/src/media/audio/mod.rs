// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
mod capture;
pub mod device_watch;

use std::{
    borrow::Cow,
    collections::{HashSet, VecDeque},
    error::Error,
    fmt::{Display, Formatter},
    sync::Arc,
    time::{Duration, Instant},
};

pub use capture::{
    AudioProcessEntry, CaptureTargetPlan, DefaultAudioResponseController,
    PlatformAudioCaptureBackend, bundle_id_matches_target, matching_process_objects,
    normalize_target_app_bundle_id, plan_capture_target,
};

use crate::project::SceneHandle;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioVolume(f32);

impl TryFrom<f32> for AudioVolume {
    type Error = AudioInputError;

    fn try_from(value: f32) -> Result<Self, Self::Error> {
        if value.is_finite() && (0.0..=1.0).contains(&value) {
            Ok(Self(value))
        } else {
            Err(AudioInputError::InvalidAudioVolume(value))
        }
    }
}

/// Shared checks of every input buffer: the rate first, then emptiness.
fn check_input(sample_rate: u32, sample_count: usize) -> Result<(), AudioInputError> {
    if sample_rate == 0 {
        return Err(AudioInputError::InvalidSampleRate);
    }
    if sample_count == 0 {
        return Err(AudioInputError::EmptyInput);
    }
    Ok(())
}

fn saturating_count(frames: usize) -> u32 {
    u32::try_from(frames).unwrap_or(u32::MAX)
}

impl From<AudioVolume> for f32 {
    fn from(value: AudioVolume) -> Self {
        value.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InterleavedStereoF32<'a> {
    sample_rate: u32,
    samples: &'a [f32],
}

impl<'a> InterleavedStereoF32<'a> {
    /// # Errors
    ///
    /// Returns [`AudioInputError`] for a zero rate, no samples or an odd sample count.
    pub fn new(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        check_input(sample_rate, samples.len())?;
        if samples.len() % 2 != 0 {
            return Err(AudioInputError::OddSampleCount(samples.len()));
        }
        Ok(Self {
            sample_rate,
            samples,
        })
    }

    #[must_use]
    pub fn sample_rate(self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(self) -> u32 {
        saturating_count(self.samples.len() / 2)
    }

    #[must_use]
    pub fn samples(self) -> &'a [f32] {
        self.samples
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MonoPcmF32<'a> {
    sample_rate: u32,
    samples: Cow<'a, [f32]>,
}

impl<'a> MonoPcmF32<'a> {
    /// # Errors
    ///
    /// Returns [`AudioInputError`] for a zero rate or no samples.
    pub fn borrowed(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        check_input(sample_rate, samples.len())?;
        Ok(Self {
            sample_rate,
            samples: Cow::Borrowed(samples),
        })
    }

    /// # Errors
    ///
    /// Returns [`AudioInputError`] for a zero rate or no samples.
    pub fn owned(sample_rate: u32, samples: Vec<f32>) -> Result<Self, AudioInputError> {
        check_input(sample_rate, samples.len())?;
        Ok(Self {
            sample_rate,
            samples: Cow::Owned(samples),
        })
    }

    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(&self) -> u32 {
        saturating_count(self.samples.len())
    }

    #[must_use]
    pub fn samples(&self) -> &[f32] {
        &self.samples
    }
}


/// Channel layout of the platform system-audio tap actually in use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioTapChannelMode {
    Mono,
    Stereo,
}

/// One fixed-size analysis block ready for the renderer, borrowed from the
/// resampler's own storage so steady-state resampling never allocates.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioResponseBlock<'a> {
    Mono(MonoPcmF32<'a>),
    Stereo(InterleavedStereoF32<'a>),
}

/// Resamples captured PCM to the fixed analysis rate, preserving the channel
/// layout it was fed: a stereo submission stays two independent channels all
/// the way to the analyser.
#[derive(Debug)]
#[allow(dead_code)]
pub struct AudioResponseResampler {
    /// Interleaved when `channels == 2`, otherwise one sample per frame.
    pending: Vec<f32>,
    channels: usize,
    source_position: f64,
    previous: [f32; 2],
    has_previous: bool,
    source_sample_rate: Option<u32>,
}

impl Default for AudioResponseResampler {
    fn default() -> Self {
        Self {
            pending: Vec::new(),
            channels: 1,
            source_position: 0.0,
            previous: [0.0; 2],
            has_previous: false,
            source_sample_rate: None,
        }
    }
}

impl AudioResponseResampler {
    /// The renderer's analysis rate (`kAudioResponseSampleRate`). The usual
    /// 48 kHz tap passes through untouched; the interpolation below has no
    /// anti-alias filter, so it must never decimate audible content.
    pub const TARGET_SAMPLE_RATE: u32 = 48_000;
    /// A 60th of a second per submission.
    pub const BLOCK_FRAMES: usize = 800;

    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends mono PCM and emits every complete fixed-size mono block.
    pub fn push_mono(
        &mut self,
        frames: &MonoPcmF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 1);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Mono(
                MonoPcmF32::borrowed(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    /// Appends interleaved stereo PCM and emits every complete fixed-size
    /// stereo block, keeping the two channels independent.
    pub fn push_stereo(
        &mut self,
        frames: &InterleavedStereoF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 2);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Stereo(
                InterleavedStereoF32::new(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    fn accept(&mut self, source_sample_rate: u32, samples: &[f32], channels: usize) {
        // Interpolation state and buffered frames belong to one rate and one
        // channel layout; either change restarts from an empty buffer.
        if self.source_sample_rate != Some(source_sample_rate) || self.channels != channels {
            if self.channels != channels {
                self.pending.clear();
                self.channels = channels;
            }
            self.source_sample_rate = Some(source_sample_rate);
            self.has_previous = false;
            self.source_position = 0.0;
        }

        if source_sample_rate == Self::TARGET_SAMPLE_RATE {
            self.pending.extend_from_slice(samples);
        } else {
            self.append_resampled(source_sample_rate, samples);
        }
    }

    fn drain_blocks(&mut self, mut emit: impl FnMut(&[f32])) {
        let block_len = Self::BLOCK_FRAMES * self.channels;
        let mut consumed = 0usize;
        while consumed + block_len <= self.pending.len() {
            emit(&self.pending[consumed..consumed + block_len]);
            consumed += block_len;
        }
        if consumed > 0 {
            // One compaction of the sub-block remainder per call, never a
            // prefix shuffle per emitted block.
            self.pending.copy_within(consumed.., 0);
            self.pending.truncate(self.pending.len() - consumed);
        }
    }

    fn append_resampled(&mut self, source_sample_rate: u32, samples: &[f32]) {
        let channels = self.channels;
        let frames = samples.len() / channels;
        if frames == 0 {
            return;
        }
        let step = f64::from(source_sample_rate) / f64::from(Self::TARGET_SAMPLE_RATE);

        // The frame carried from the previous call (when there is one) sits in
        // front of this call's frames, so the walk sees one continuous run.
        let carried = self.has_previous;
        let previous = self.previous;
        let total = frames + usize::from(carried);
        let frame_value = |index: usize, channel: usize| -> f32 {
            if carried {
                if index == 0 {
                    previous[channel]
                } else {
                    samples[(index - 1) * channels + channel]
                }
            } else {
                samples[index * channels + channel]
            }
        };

        let mut position = self.source_position;
        let reachable = (total - 1) as f64 - position;
        if reachable > 0.0 {
            self.pending
                .reserve(((reachable / step) as usize + 1) * channels);
        }
        loop {
            let index = position.floor() as usize;
            if index + 1 >= total {
                break;
            }
            let fraction = (position - index as f64) as f32;
            for channel in 0..channels {
                let from = frame_value(index, channel);
                let to = frame_value(index + 1, channel);
                self.pending.push(from + (to - from) * fraction);
            }
            position += step;
        }

        for channel in 0..channels {
            self.previous[channel] = frame_value(total - 1, channel);
        }
        self.has_previous = true;
        self.source_position = position - (total - 1) as f64;
    }


    #[cfg(test)]
    #[must_use]
    pub fn pending_for_testing(&self) -> &[f32] {
        &self.pending
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AudioInputError {
    InvalidSampleRate,
    EmptyInput,
    InvalidAudioVolume(f32),
    OddSampleCount(usize),
}

impl Display for AudioInputError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSampleRate => f.write_str("sample_rate must be greater than zero"),
            Self::EmptyInput => f.write_str("samples must not be empty"),
            Self::InvalidAudioVolume(value) => {
                write!(f, "audio volume must be between 0.0 and 1.0, got {value}")
            }
            Self::OddSampleCount(count) => {
                write!(f, "samples must contain stereo pairs, got {count} values")
            }
        }
    }
}

impl Error for AudioInputError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioCaptureError {
    UnsupportedPlatform,
    PermissionDenied(String),
    Platform(String),
    CoreAudio { operation: &'static str, status: i32 },
    Engine(String),
}

impl Display for AudioCaptureError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedPlatform => {
                f.write_str("system audio capture is not supported on this platform")
            }
            Self::CoreAudio { operation, status } => {
                write!(f, "Core Audio call {operation} returned error status {status}")?;
                let tag = status.to_be_bytes();
                if tag.iter().all(u8::is_ascii_graphic) {
                    write!(f, " / four-char code {:?}", String::from_utf8_lossy(&tag))?;
                }
                Ok(())
            }
            Self::PermissionDenied(message)
            | Self::Platform(message)
            | Self::Engine(message) => f.write_str(message),
        }
    }
}

impl Error for AudioCaptureError {}

pub trait AudioFrameConsumer: Send + Sync {
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError>;

    /// Consumers must not satisfy this by duplicating the mono samples into an
    /// interleaved pair and forwarding them to [`Self::submit_audio_frames`]:
    /// downstream analysis reports a two-channel submission as stereo, and a
    /// mono source is not stereo.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError>;
}

pub trait AudioResponseEngine: AudioFrameConsumer {
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine cannot update the scene.
    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError>;
}

pub trait AudioCaptureBackend {
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission check fails.
    fn has_permission(&self) -> Result<bool, AudioCaptureError>;
    /// Requests permission or allows a subsequent capture startup to request it.
    ///
    /// The macOS CoreAudio backend only records a hint here; OS authorization
    /// happens when tap recording starts. A `true` result is not an OS grant.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission prompt or
    /// status check fails.
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError>;
    /// Starts usable capture, completing any pending cleanup before creating a
    /// replacement session. A backend reporting pending cleanup must not treat
    /// its retained resources as an already healthy capture or overlap sessions.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform capture setup or cleanup fails.
    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError>;
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform teardown fails.
    fn stop(&mut self) -> Result<(), AudioCaptureError>;
    /// Whether capture is healthy and usable, not merely still owned.
    #[must_use]
    fn is_running(&self) -> bool;
    /// Whether resources from unfinished teardown are still owned. A backend
    /// may report this even after native recording has stopped. Even if a backend
    /// reports both queries true, pending cleanup means capture is not usable.
    /// Controllers must retry cleanup before treating an owned session as usable
    /// or fully stopped.
    /// Backends without partial teardown need not override this query.
    #[must_use]
    fn has_pending_cleanup(&self) -> bool {
        false
    }
    /// How many times the running tap's I/O callback has been called since
    /// that tap started, or `None` when no healthy tap runs or the backend
    /// cannot count them. Every call counts, whether it carries sound or
    /// silence. Only a counting backend is checked for a stalled tap.
    #[must_use]
    fn io_callback_count(&self) -> Option<u64> {
        None
    }
    /// Whether the default output device is running for any client. A tap is
    /// expected to call back only then, so missing callbacks count as a stall
    /// only while this is true. A backend that cannot tell reports `false`.
    #[must_use]
    fn output_device_is_running(&self) -> bool {
        false
    }
    /// Configures an optional target application bundle ID for per-app audio
    /// capture. `None` captures all system audio excluding this process.
    fn set_target_app_bundle_id(&mut self, bundle_id: Option<String>) {
        let _ = bundle_id;
    }
    /// Returns the currently configured target application bundle ID, if any.
    #[must_use]
    fn target_app_bundle_id(&self) -> Option<&str> {
        None
    }
    /// Whether capture is intentionally idling because a target app is
    /// configured and currently has no active audio processes.
    #[must_use]
    fn is_idle_for_target(&self) -> bool {
        false
    }
    /// Re-evaluates the CoreAudio process list for a configured target app.
    /// Returns `Ok(true)` when capture attached, switched process IDs, or
    /// transitioned to clean idle; `Ok(false)` when no change was needed.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when teardown or tap startup fails.
    fn sync_target_processes(
        &mut self,
        consumer: Arc<dyn AudioFrameConsumer>,
    ) -> Result<bool, AudioCaptureError> {
        let _ = consumer;
        Ok(false)
    }
}

/// How long to wait before each further attempt to bring the tap back after a
/// rebuild failed. The first attempt is immediate; these are the retries, so a
/// rebuild is tried four times in all before it is left to the next scene or
/// demand change.
pub const RESTART_RETRY_DELAYS: [Duration; 3] = [
    Duration::from_millis(500),
    Duration::from_millis(1000),
    Duration::from_millis(1500),
];

/// What [`AudioCaptureController::restart_capture`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestartOutcome {
    /// Nothing was rebuilt: nobody wants capture right now, it is suspended, or
    /// it was never running.
    NotRunning,
    /// The tap was stopped and started again.
    Restarted,
}

/// How often the capture worker checks a running tap for missing callbacks.
pub const TAP_STALL_CHECK_INTERVAL: Duration = Duration::from_secs(1);
/// How long a running tap may go without one I/O callback, while the output
/// device runs, before it counts as stalled and is rebuilt.
pub const TAP_STALL_TIMEOUT: Duration = Duration::from_secs(3);
/// At most this many stall rebuilds within [`TAP_STALL_REBUILD_WINDOW`]. The
/// next stall inside that window ends the watch until a scene or demand
/// change, so a device that keeps stalling cannot loop.
pub const TAP_STALL_REBUILD_LIMIT: usize = 3;
/// The sliding window [`TAP_STALL_REBUILD_LIMIT`] counts stall rebuilds in.
pub const TAP_STALL_REBUILD_WINDOW: Duration = Duration::from_secs(60);

/// What one [`AudioCaptureController::check_tap_stall`] found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TapStallCheck {
    /// Nothing is watched: capture is not wanted or not healthy, the backend
    /// cannot count callbacks, or the watch gave up.
    Idle,
    /// The tap called back recently, or the output device is not running and
    /// no callback is expected.
    Healthy,
    /// The first callback after a stall rebuild arrived.
    Recovered,
    /// No callback for [`TAP_STALL_TIMEOUT`] while the output device runs.
    /// The caller rebuilds the tap now; the rebuild counts against the limit.
    Stalled,
    /// Stalled again after [`TAP_STALL_REBUILD_LIMIT`] rebuilds within
    /// [`TAP_STALL_REBUILD_WINDOW`]: the watch stops until a scene or demand
    /// change.
    GaveUp,
}

/// Notices a running tap whose I/O callback is no longer called.
///
/// It keys off the backend's callback count, never off the samples: a healthy
/// tap keeps calling back with zeros while nothing plays.
#[derive(Debug, Default)]
struct TapStallWatch {
    /// The callback count last seen and when it was first seen at that value.
    /// `None` until the current tap's first check.
    last: Option<(u64, Instant)>,
    /// When each stall rebuild inside the window was asked for, oldest first.
    rebuilds: VecDeque<Instant>,
    gave_up: bool,
    /// A stall rebuild was asked for and no callback has been seen since.
    awaiting_recovery: bool,
    /// The previous check saw a callback or found the output device running,
    /// so the wait since `last` is time the device ran.
    output_ran_since_last: bool,
}

impl TapStallWatch {
    /// A new tap started. Its count starts at zero and its wait at its first
    /// check.
    fn tap_started(&mut self) {
        self.last = None;
        self.output_ran_since_last = false;
    }

    /// A scene or demand change gives a watch that gave up a fresh budget.
    fn rearm(&mut self) {
        self.gave_up = false;
        self.rebuilds.clear();
    }

    /// One check at `now` of a tap that has called back `count` times since
    /// it started.
    fn observe(
        &mut self,
        now: Instant,
        count: u64,
        output_running: impl FnOnce() -> bool,
    ) -> TapStallCheck {
        // A tap's count starts at zero, so at its first check any call counts.
        let delivered = self.last.map_or(count > 0, |(seen, _)| count != seen);
        if delivered || self.last.is_none() {
            self.last = Some((count, now));
        }
        if delivered {
            self.output_ran_since_last = true;
            return if std::mem::take(&mut self.awaiting_recovery) {
                TapStallCheck::Recovered
            } else {
                TapStallCheck::Healthy
            };
        }
        // The device is asked only while callbacks are missing. While it is
        // idle no callback is expected, so the wait starts again.
        if !output_running() {
            self.last = Some((count, now));
            self.output_ran_since_last = false;
            return TapStallCheck::Healthy;
        }
        // The device was idle at the previous check: only from now does a
        // missing callback count.
        if !std::mem::replace(&mut self.output_ran_since_last, true) {
            self.last = Some((count, now));
            return TapStallCheck::Healthy;
        }
        let waited = self
            .last
            .map_or(Duration::ZERO, |(_, since)| now.saturating_duration_since(since));
        if waited < TAP_STALL_TIMEOUT {
            return TapStallCheck::Healthy;
        }
        while self.rebuilds.front().is_some_and(|&asked| {
            now.saturating_duration_since(asked) >= TAP_STALL_REBUILD_WINDOW
        }) {
            self.rebuilds.pop_front();
        }
        if self.rebuilds.len() >= TAP_STALL_REBUILD_LIMIT {
            self.gave_up = true;
            self.awaiting_recovery = false;
            return TapStallCheck::GaveUp;
        }
        self.rebuilds.push_back(now);
        self.awaiting_recovery = true;
        TapStallCheck::Stalled
    }
}

pub struct AudioCaptureController<B: AudioCaptureBackend> {
    consumer: Arc<dyn AudioFrameConsumer>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
    suspended: bool,
    external_consumers: bool,
    /// A rebuild owes a fresh start after failed teardown or startup. Capture is
    /// still wanted, so the next [`AudioCaptureController::restart_capture`]
    /// retries it without requiring another device change.
    restart_pending: bool,
    stall: TapStallWatch,
}

impl<B: AudioCaptureBackend> AudioCaptureController<B> {
    #[must_use]
    pub fn new(consumer: Arc<dyn AudioFrameConsumer>, backend: B) -> Self {
        Self {
            consumer,
            backend,
            enabled_handles: HashSet::new(),
            suspended: false,
            external_consumers: false,
            restart_pending: false,
            stall: TapStallWatch::default(),
        }
    }

    /// Returns the backend's current permission status or capture-start hint.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// Requests permission (or enables the backend's startup authorization path)
    /// and starts capture if scenes are already enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture_state()?;
        }
        Ok(granted)
    }

    /// Enables or disables capture for one scene.
    /// Scenes remain pending when permission is unavailable. A failed new
    /// activation is rolled back; removals remain committed even if stopping
    /// fails, so departed scenes never retain capture ownership.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when synchronizing backend capture state
    /// fails.
    pub fn set_scene_capturing(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        if enabled {
            let newly_added = self.enabled_handles.insert(handle);
            if newly_added {
                self.stall.rearm();
            }
            if let Err(error) = self.sync_capture_state() {
                if newly_added {
                    self.enabled_handles.remove(&handle);
                }
                return Err(error);
            }
            Ok(())
        } else {
            if self.enabled_handles.remove(&handle) {
                self.stall.rearm();
            }
            self.sync_capture_state()
        }
    }

    /// Releases capture ownership for scenes absent from `handles`.
    ///
    /// Removals are committed even if backend synchronization fails. Calling
    /// this again retries synchronization without resurrecting departed scenes.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn retain_scenes(&mut self, handles: &[SceneHandle]) -> Result<(), AudioCaptureError> {
        let before = self.enabled_handles.len();
        self.enabled_handles
            .retain(|handle| handles.contains(handle));
        if self.enabled_handles.len() != before {
            self.stall.rearm();
        }
        self.sync_capture_state()
    }

    /// Updates presentation suspension and demand from consumers without scene
    /// handles (such as web pages) together, without briefly restarting capture.
    /// Scene ownership is preserved. A failed transition restores both inputs.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn set_demand(
        &mut self,
        suspended: bool,
        external_consumers: bool,
    ) -> Result<(), AudioCaptureError> {
        let previous = (self.suspended, self.external_consumers);
        self.suspended = suspended;
        self.external_consumers = external_consumers;
        if previous != (suspended, external_consumers) {
            self.stall.rearm();
        }
        if let Err(error) = self.sync_capture_state() {
            (self.suspended, self.external_consumers) = previous;
            if let Err(rollback) = self.sync_capture_state() {
                return Err(AudioCaptureError::Platform(format!(
                    "{error}; audio capture rollback failed: {rollback}"
                )));
            }
            return Err(error);
        }
        Ok(())
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running() && !self.backend.has_pending_cleanup()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn has_scene_consumer(&self, handle: SceneHandle) -> bool {
        self.enabled_handles.contains(&handle)
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    /// Stops the tap and starts it again, for a change underneath it such as a
    /// new default output device.
    ///
    /// Only a running tap or unfinished capture cleanup is rebuilt, and only
    /// while capture is wanted. A rebuild never asks for permission again;
    /// a controller that was never started and has no pending cleanup does
    /// nothing. Without demand, remaining resources are only released, never
    /// restarted. If teardown or startup fails, the error is returned and the
    /// next call retries the owed rebuild without a second device change.
    /// Any scene or demand change that starts healthy capture also heals it.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when stopping or starting the tap fails.
    pub fn restart_capture(&mut self) -> Result<RestartOutcome, AudioCaptureError> {
        if !self.wants_capture() {
            self.restart_pending = false;
            if self.backend.is_running()
                || self.backend.has_pending_cleanup()
                || self.backend.is_idle_for_target()
            {
                self.backend.stop()?;
            }
            return Ok(RestartOutcome::NotRunning);
        }
        if self.backend.is_running() || self.backend.has_pending_cleanup() {
            // Record the owed rebuild before teardown: it may stop recording but
            // fail to release a later resource, leaving no healthy running tap.
            self.restart_pending = true;
            self.backend.stop()?;
        } else if !self.restart_pending {
            return Ok(RestartOutcome::NotRunning);
        }
        if !self.backend.has_permission()? {
            return Ok(RestartOutcome::NotRunning);
        }
        self.start_backend()?;
        if self.is_capturing() || self.backend.is_idle_for_target() {
            self.restart_pending = false;
        }
        Ok(if self.backend.is_idle_for_target() {
            RestartOutcome::NotRunning
        } else {
            RestartOutcome::Restarted
        })
    }

    /// Configures an optional target application bundle ID for per-app audio
    /// capture (`None` captures all system audio excluding this process).
    ///
    /// A failed transition rolls the backend's target bundle ID back to the
    /// previous setting and attempts to restore capture state so the backend
    /// and process-list watcher stay consistent with persisted configuration.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission checking, stopping the
    /// previous tap, or starting the replacement tap fails.
    pub fn set_target_app_bundle_id(
        &mut self,
        bundle_id: Option<String>,
    ) -> Result<(), AudioCaptureError> {
        let normalized = normalize_target_app_bundle_id(bundle_id.as_deref());
        if self.backend.target_app_bundle_id() == normalized.as_deref() {
            return Ok(());
        }
        let permitted = if self.wants_capture() {
            self.backend.has_permission()?
        } else {
            false
        };
        let previous = self.backend.target_app_bundle_id().map(ToOwned::to_owned);
        let was_active_or_idle = self.backend.is_running()
            || self.backend.has_pending_cleanup()
            || self.backend.is_idle_for_target();
        if was_active_or_idle
            && let Err(error) = self.backend.stop()
        {
            if self.backend.has_pending_cleanup() && self.wants_capture() {
                self.restart_pending = true;
            }
            return Err(error);
        }
        self.backend.set_target_app_bundle_id(normalized);
        self.stall.rearm();
        if permitted {
            if let Err(error) = self.start_backend() {
                self.backend.set_target_app_bundle_id(previous);
                if was_active_or_idle
                    && let Err(rollback) = self.sync_capture_state()
                {
                    self.restart_pending = true;
                    return Err(AudioCaptureError::Platform(format!(
                        "{error}; audio capture rollback failed: {rollback}"
                    )));
                }
                return Err(error);
            }
            if self.is_capturing() || self.backend.is_idle_for_target() {
                self.restart_pending = false;
            }
        }
        Ok(())
    }

    #[must_use]
    pub fn target_app_bundle_id(&self) -> Option<&str> {
        self.backend.target_app_bundle_id()
    }

    #[must_use]
    pub fn is_idle_for_target(&self) -> bool {
        self.backend.is_idle_for_target()
    }

    /// Whether a `ProcessListWatcher` should be running: capture is wanted and
    /// a per-app target bundle ID is configured.
    #[must_use]
    pub fn wants_process_list_watch(&self) -> bool {
        self.wants_capture() && self.backend.target_app_bundle_id().is_some()
    }

    /// Re-evaluates the CoreAudio process list after a
    /// `kAudioHardwarePropertyProcessObjectList` notification.
    ///
    /// Returns `Ok(true)` when capture attached, rebuilt for updated process
    /// objects, or transitioned to idle; `Ok(false)` when no change was needed.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when tearing down or starting a tap fails.
    pub fn handle_process_list_change(&mut self) -> Result<bool, AudioCaptureError> {
        if !self.wants_capture() || self.backend.target_app_bundle_id().is_none() {
            return Ok(false);
        }
        if !self.backend.has_permission()? {
            return Ok(false);
        }
        match self
            .backend
            .sync_target_processes(Arc::clone(&self.consumer))
        {
            Ok(changed) => {
                if changed {
                    if self.is_capturing() {
                        self.stall.tap_started();
                        self.restart_pending = false;
                    } else if self.backend.is_idle_for_target() {
                        self.restart_pending = false;
                    }
                }
                Ok(changed)
            }
            Err(error) => {
                if !self.is_capturing() {
                    self.restart_pending = true;
                }
                Err(error)
            }
        }
    }

    /// Whether a tap should be running right now: capture is not suspended
    /// and a scene or another consumer needs it. A change of output device
    /// matters only then, so this is what a caller watching for one keys off.
    #[must_use]
    pub fn wants_capture(&self) -> bool {
        !self.suspended && (self.external_consumers || !self.enabled_handles.is_empty())
    }

    /// Whether [`Self::check_tap_stall`] has anything to check: capture is
    /// wanted, a tap whose callbacks the backend counts is running, and the
    /// watch has not given up. A caller schedules the check only while this
    /// holds, so a stopped, suspended or uncounted tap costs nothing.
    #[must_use]
    pub fn watches_tap_stall(&self) -> bool {
        !self.stall.gave_up && self.wants_capture() && self.backend.io_callback_count().is_some()
    }

    /// Checks the running tap for missing I/O callbacks, once per
    /// [`TAP_STALL_CHECK_INTERVAL`] at `now`.
    ///
    /// Only the absence of callbacks counts, never silent samples, and only
    /// while the default output device runs. On [`TapStallCheck::Stalled`]
    /// the caller rebuilds the tap the way it rebuilds one for a device
    /// change, through [`Self::restart_capture`], which never asks for
    /// permission again.
    #[must_use]
    pub fn check_tap_stall(&mut self, now: Instant) -> TapStallCheck {
        if self.stall.gave_up || !self.wants_capture() || !self.is_capturing() {
            return TapStallCheck::Idle;
        }
        let Some(count) = self.backend.io_callback_count() else {
            return TapStallCheck::Idle;
        };
        let backend = &self.backend;
        self.stall
            .observe(now, count, || backend.output_device_is_running())
    }

    fn start_backend(&mut self) -> Result<(), AudioCaptureError> {
        self.backend.start(Arc::clone(&self.consumer))?;
        // A new tap waits its own timeout before it can count as stalled.
        self.stall.tap_started();
        Ok(())
    }

    fn sync_capture_state(&mut self) -> Result<(), AudioCaptureError> {
        let wanted = self.wants_capture();
        let running = self.backend.is_running();
        let idle_for_target = self.backend.is_idle_for_target();
        let cleanup = self.backend.has_pending_cleanup();
        let outcome = if wanted && ((!running && !idle_for_target) || cleanup || self.restart_pending)
        {
            match self.backend.has_permission() {
                Ok(true) => self.start_backend(),
                Ok(false) => Ok(()),
                Err(error) => Err(error),
            }
        } else if !wanted && (running || idle_for_target || cleanup) {
            self.backend.stop()
        } else {
            Ok(())
        };
        if !wanted || (outcome.is_ok() && (self.is_capturing() || self.backend.is_idle_for_target()))
        {
            self.restart_pending = false;
        }
        outcome
    }
}

impl<B: AudioCaptureBackend> Drop for AudioCaptureController<B> {
    fn drop(&mut self) {
        if self.backend.is_running()
            || self.backend.has_pending_cleanup()
            || self.backend.is_idle_for_target()
        {
            let _ = self.backend.stop();
        }
    }
}

pub struct AudioResponseController<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> {
    engine: Arc<E>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> AudioResponseController<E, B> {
    #[must_use]
    pub fn new(engine: Arc<E>, backend: B) -> Self {
        Self {
            engine,
            backend,
            enabled_handles: HashSet::new(),
        }
    }

    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture()?;
        }
        Ok(granted)
    }

    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine update or capture state
    /// sync fails.
    pub fn set_scene_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        self.engine.set_audio_response_enabled(handle, enabled)?;
        if enabled {
            self.enabled_handles.insert(handle);
        } else {
            self.enabled_handles.remove(&handle);
        }
        self.sync_capture()
    }

    /// Capture runs exactly while at least one scene is enabled and permission is held.
    fn sync_capture(&mut self) -> Result<(), AudioCaptureError> {
        let wanted = !self.enabled_handles.is_empty();
        let running = self.backend.is_running();
        let cleanup = self.backend.has_pending_cleanup();
        if wanted && (!running || cleanup) {
            if self.backend.has_permission()? {
                let engine: Arc<E> = Arc::clone(&self.engine);
                self.backend.start(engine)?;
            }
        } else if !wanted && (running || cleanup) {
            self.backend.stop()?;
        }
        Ok(())
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running() && !self.backend.has_pending_cleanup()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> Drop
    for AudioResponseController<E, B>
{
    fn drop(&mut self) {
        if self.backend.is_running() || self.backend.has_pending_cleanup() {
            let _ = self.backend.stop();
        }
    }
}

#[cfg(test)]
mod capture_controller_tests {
    use super::*;

    #[derive(Default)]
    struct TestConsumer;

    impl AudioFrameConsumer for TestConsumer {
        fn submit_audio_frames(
            &self,
            _frames: InterleavedStereoF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }

        fn submit_mono_audio_frames(
            &self,
            _frames: MonoPcmF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }
    }

    #[derive(Default)]
    struct TestBackend {
        running: bool,
        permission_pending: bool,
        fail_start: bool,
        fail_stop: bool,
        starts: usize,
        stops: usize,
    }

    impl AudioCaptureBackend for TestBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            Ok(!self.permission_pending)
        }

        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.permission_pending = false;
            Ok(true)
        }

        fn start(
            &mut self,
            _consumer: Arc<dyn AudioFrameConsumer>,
        ) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_start) {
                return Err(AudioCaptureError::Platform("start failed".into()));
            }
            self.running = true;
            self.starts += 1;
            Ok(())
        }

        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_stop) {
                return Err(AudioCaptureError::Platform("stop failed".into()));
            }
            self.running = false;
            self.stops += 1;
            Ok(())
        }

        fn is_running(&self) -> bool {
            self.running
        }
    }

    #[test]
    fn external_consumers_capture_without_scenes_and_share_the_existing_tap() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing(), "resume alone is not capture demand");
        controller.set_demand(false, true).unwrap();
        assert!(controller.is_capturing(), "a web-only session needs no scene handle");
        assert_eq!(controller.active_scene_count(), 0);
        controller.set_demand(false, true).unwrap();
        controller.retain_scenes(&[]).unwrap();
        assert!(controller.is_capturing(), "scene cleanup must preserve web ownership");

        let handle = SceneHandle::new(7);
        controller.set_scene_capturing(handle, true).unwrap();
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "the scene still owns capture");
        controller.set_demand(false, true).unwrap();
        controller.retain_scenes(&[]).unwrap();
        assert_eq!(controller.backend().starts, 1, "all consumers share one tap");
        assert_eq!(controller.backend().stops, 0);
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.backend().stops, 1);
    }

    #[test]
    fn external_demand_obeys_suspension_and_permission() {
        let backend = TestBackend { permission_pending: true, ..TestBackend::default() };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller.set_demand(true, true).unwrap();
        controller.request_permission().unwrap();
        assert!(!controller.is_capturing(), "permission does not override suspension");
        controller.set_demand(false, true).unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, true).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing(), "a departed page must not resume capture");

        controller.backend.permission_pending = true;
        controller.set_demand(false, true).unwrap();
        assert!(!controller.is_capturing());
        controller.request_permission().unwrap();
        assert!(controller.is_capturing(), "pending external demand survives authorization");
    }

    #[test]
    fn failed_external_transition_restores_both_demand_inputs() {
        let backend = TestBackend { fail_start: true, ..TestBackend::default() };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller.set_demand(true, false).unwrap();
        assert!(controller.set_demand(false, true).is_err());
        controller.retain_scenes(&[]).unwrap();
        assert!(!controller.is_capturing(), "failed subscription left no demand");
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, true).unwrap();
        controller.backend.fail_stop = true;
        assert!(controller.set_demand(true, false).is_err());
        controller.retain_scenes(&[]).unwrap();
        assert!(controller.is_capturing(), "failed stop restores the running intent");
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
    }

    #[test]
    fn retaining_scenes_stops_capture_only_after_final_owner_departs() {
        let consumer = Arc::new(TestConsumer);
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(consumer, backend);
        let handle = SceneHandle::new(7);

        controller.set_scene_capturing(handle, true).unwrap();
        let other = SceneHandle::new(8);
        controller.set_scene_capturing(other, true).unwrap();
        controller.retain_scenes(&[other]).unwrap();

        assert!(controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);
        controller.retain_scenes(&[]).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 0);
    }

    #[test]
    fn failed_new_activation_does_not_leave_capture_ownership() {
        let backend = TestBackend {
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        assert!(
            controller
                .set_scene_capturing(SceneHandle::new(7), true)
                .is_err()
        );
        assert_eq!(controller.active_scene_count(), 0);
        controller.request_permission().unwrap();
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(8), true)
            .unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn pending_scene_survives_failed_permission_start_and_repeated_enable() {
        let backend = TestBackend {
            permission_pending: true,
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        let handle = SceneHandle::new(7);
        controller.set_scene_capturing(handle, true).unwrap();
        assert!(!controller.is_capturing());
        assert!(controller.request_permission().is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.backend.fail_start = true;
        assert!(controller.set_scene_capturing(handle, true).is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.request_permission().unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn removals_stay_committed_when_stop_fails_and_allow_teardown_retry() {
        for retain in [false, true] {
            let backend = TestBackend {
                fail_stop: true,
                ..TestBackend::default()
            };
            let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
            let handle = SceneHandle::new(7);
            controller.set_scene_capturing(handle, true).unwrap();
            let result = if retain {
                controller.retain_scenes(&[])
            } else {
                controller.set_scene_capturing(handle, false)
            };
            assert!(result.is_err());
            assert_eq!(controller.active_scene_count(), 0);
            assert!(controller.is_capturing());
            controller.retain_scenes(&[]).unwrap();
            assert!(!controller.is_capturing());
        }
    }

    #[test]
    fn suspending_stops_capture_and_resuming_restores_enabled_scenes() {
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        assert!(controller.is_capturing());

        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);

        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn failed_resume_preserves_suspension_across_capture_updates() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.set_demand(true, false).unwrap();
        controller.backend.fail_start = true;

        let error = controller.set_demand(false, false).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("start failed".into()));
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(!controller.is_capturing());

        controller.set_demand(true, false).unwrap();
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 2);
    }

    #[test]
    fn restart_rebuilds_a_running_capture_once() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert_eq!(controller.backend().starts, 1, "two scenes share one tap");

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);

        assert!(controller.is_capturing());
        assert_eq!(controller.backend().stops, 1, "the old tap is released first");
        assert_eq!(controller.backend().starts, 2, "one new tap serves both scenes");
        assert_eq!(controller.active_scene_count(), 2);
    }

    #[test]
    fn restart_is_a_no_op_while_stopped() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);
        assert_eq!((controller.backend().starts, controller.backend().stops), (0, 0));

        // Capture is wanted but waiting for authorization: a device change
        // must not start it, because starting is what asks for permission.
        let backend = TestBackend { permission_pending: true, ..TestBackend::default() };
        let mut waiting = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        waiting.set_scene_capturing(SceneHandle::new(1), true).unwrap();
        assert_eq!(waiting.restart_capture().unwrap(), RestartOutcome::NotRunning);
        assert_eq!(waiting.backend().starts, 0);
        assert!(!waiting.is_capturing());
    }

    #[test]
    fn restart_is_a_no_op_while_suspended() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        let (starts, stops) = (controller.backend().starts, controller.backend().stops);

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);

        assert_eq!((controller.backend().starts, controller.backend().stops), (starts, stops));
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "resuming starts a tap on the current device");
    }

    #[test]
    fn a_failed_restart_leaves_capture_stopped_and_the_next_sync_starts_it() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_start = true;

        let error = controller.restart_capture().unwrap_err();

        assert_eq!(error, AudioCaptureError::Platform("start failed".into()));
        assert!(!controller.is_capturing(), "the old tap is gone and no new one started");
        assert_eq!(controller.active_scene_count(), 1, "the scene keeps its claim on capture");
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "the next scene or demand change heals it");
    }

    #[test]
    fn a_failed_restart_can_be_retried_without_another_device_change() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_start = true;
        assert!(controller.restart_capture().is_err());
        assert!(!controller.is_capturing());

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);

        assert!(controller.is_capturing());
        assert_eq!(controller.backend().starts, 2);
        assert_eq!(
            controller.restart_capture().unwrap(),
            RestartOutcome::Restarted,
            "a healthy tap is rebuilt again on the next device change"
        );
        assert_eq!(controller.backend().starts, 3);
    }

    #[test]
    fn a_pending_restart_is_dropped_once_nobody_wants_capture() {
        for release in [
            |controller: &mut AudioCaptureController<TestBackend>| {
                controller.set_scene_capturing(SceneHandle::new(1), false).unwrap();
            },
            |controller: &mut AudioCaptureController<TestBackend>| {
                controller.set_demand(true, false).unwrap();
            },
        ] {
            let mut controller =
                AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
            controller
                .set_scene_capturing(SceneHandle::new(1), true)
                .unwrap();
            controller.backend.fail_start = true;
            assert!(controller.restart_capture().is_err());

            release(&mut controller);
            assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);

            assert!(!controller.is_capturing());
            assert_eq!(controller.backend().starts, 1, "a stale retry never starts a tap");
        }
    }

    #[test]
    fn failed_suspend_preserves_running_capture_intent() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_stop = true;

        let error = controller.set_demand(true, false).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("stop failed".into()));
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
    }

    #[derive(Default)]
    struct TargetAppBackend {
        running: bool,
        idle_for_target: bool,
        permission_pending: bool,
        fail_start_count: usize,
        fail_stop: bool,
        target_app: Option<String>,
        available_processes: Vec<AudioProcessEntry>,
        tapped_processes: Vec<u32>,
        starts: usize,
        stops: usize,
    }

    impl AudioCaptureBackend for TargetAppBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            Ok(!self.permission_pending)
        }
        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.permission_pending = false;
            Ok(true)
        }
        fn start(&mut self, _: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
            match plan_capture_target(
                self.target_app.as_deref(),
                &self.available_processes,
                9999,
                None,
            ) {
                CaptureTargetPlan::GlobalExcludingSelf => {
                    if self.fail_start_count > 0 {
                        self.fail_start_count -= 1;
                        return Err(AudioCaptureError::Platform("target start failed".into()));
                    }
                    self.running = true;
                    self.idle_for_target = false;
                    self.tapped_processes.clear();
                    self.starts += 1;
                }
                CaptureTargetPlan::Processes(ids) => {
                    if self.fail_start_count > 0 {
                        self.fail_start_count -= 1;
                        return Err(AudioCaptureError::Platform("target start failed".into()));
                    }
                    self.running = true;
                    self.idle_for_target = false;
                    self.tapped_processes = ids;
                    self.starts += 1;
                }
                CaptureTargetPlan::IdleWaitingForTarget => {
                    self.running = false;
                    self.idle_for_target = true;
                    self.tapped_processes.clear();
                }
            }
            Ok(())
        }
        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_stop) {
                return Err(AudioCaptureError::Platform("target stop failed".into()));
            }
            if self.running {
                self.stops += 1;
            }
            self.running = false;
            self.idle_for_target = false;
            self.tapped_processes.clear();
            Ok(())
        }
        fn is_running(&self) -> bool {
            self.running
        }
        fn io_callback_count(&self) -> Option<u64> {
            self.running.then_some(0)
        }
        fn set_target_app_bundle_id(&mut self, bundle_id: Option<String>) {
            self.target_app = normalize_target_app_bundle_id(bundle_id.as_deref());
        }
        fn target_app_bundle_id(&self) -> Option<&str> {
            self.target_app.as_deref()
        }
        fn is_idle_for_target(&self) -> bool {
            self.idle_for_target
        }
        fn sync_target_processes(
            &mut self,
            consumer: Arc<dyn AudioFrameConsumer>,
        ) -> Result<bool, AudioCaptureError> {
            if self.target_app.is_none() {
                return Ok(false);
            }
            match plan_capture_target(
                self.target_app.as_deref(),
                &self.available_processes,
                9999,
                None,
            ) {
                CaptureTargetPlan::Processes(ids) => {
                    if self.running && !self.idle_for_target && self.tapped_processes == ids {
                        return Ok(false);
                    }
                    let was_idle = self.idle_for_target;
                    self.stop()?;
                    if let Err(error) = self.start(consumer) {
                        self.idle_for_target = was_idle;
                        return Err(error);
                    }
                    Ok(true)
                }
                CaptureTargetPlan::IdleWaitingForTarget => {
                    if self.idle_for_target && !self.running {
                        return Ok(false);
                    }
                    self.stop()?;
                    self.idle_for_target = true;
                    Ok(true)
                }
                CaptureTargetPlan::GlobalExcludingSelf => Ok(false),
            }
        }
    }

    #[test]
    fn per_app_target_idles_cleanly_attaches_on_process_change_and_falls_back_to_global() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TargetAppBackend::default());
        controller
            .set_target_app_bundle_id(Some("  com.spotify.client  ".to_owned()))
            .unwrap();
        assert_eq!(controller.target_app_bundle_id(), Some("com.spotify.client"));
        assert!(!controller.wants_process_list_watch(), "no watch while nothing wants capture");

        // Demand arrives while Spotify is not running: idle cleanly with zero tap errors.
        controller
            .set_scene_capturing(SceneHandle::new(41), true)
            .unwrap();
        assert!(controller.wants_process_list_watch());
        assert!(controller.is_idle_for_target());
        assert!(!controller.is_capturing());
        assert!(!controller.watches_tap_stall(), "idle waiting must schedule zero timers");
        assert_eq!(controller.backend().starts, 0);

        // An unrelated app launches: process-list notification is a no-op.
        controller.backend.available_processes.push(AudioProcessEntry {
            object_id: 101,
            pid: Some(11),
            bundle_id: Some("com.apple.Safari".to_owned()),
        });
        assert!(!controller.handle_process_list_change().unwrap());
        assert!(controller.is_idle_for_target());
        assert_eq!(controller.backend().starts, 0);

        // Target app launches: attaches automatically with case-insensitive bundle match.
        controller.backend.available_processes.push(AudioProcessEntry {
            object_id: 202,
            pid: Some(22),
            bundle_id: Some("com.Spotify.Client".to_owned()),
        });
        assert!(controller.handle_process_list_change().unwrap());
        assert!(controller.is_capturing());
        assert!(!controller.is_idle_for_target());
        assert_eq!(controller.backend().tapped_processes, vec![202]);
        assert_eq!(controller.backend().starts, 1);

        // Another unrelated app changes: running tap is left untouched.
        controller.backend.available_processes.push(AudioProcessEntry {
            object_id: 303,
            pid: Some(33),
            bundle_id: Some("com.apple.Music".to_owned()),
        });
        assert!(!controller.handle_process_list_change().unwrap());
        assert_eq!(controller.backend().starts, 1);
        assert_eq!(controller.backend().stops, 0);

        // Target app quits: stops tap cleanly and idles without errors.
        controller
            .backend
            .available_processes
            .retain(|entry| entry.object_id != 202);
        assert!(controller.handle_process_list_change().unwrap());
        assert!(!controller.is_capturing());
        assert!(controller.is_idle_for_target());
        assert_eq!(controller.backend().stops, 1);

        // Switching back to None ("All apps") falls back immediately to global tap.
        controller.set_target_app_bundle_id(None).unwrap();
        assert_eq!(controller.target_app_bundle_id(), None);
        assert!(!controller.wants_process_list_watch());
        assert!(controller.is_capturing());
        assert!(!controller.is_idle_for_target());
        assert!(controller.backend().tapped_processes.is_empty());
        assert_eq!(controller.backend().starts, 2);
    }

    #[test]
    fn process_list_change_respects_suspension_and_permission() {
        let backend = TargetAppBackend {
            permission_pending: true,
            ..TargetAppBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller
            .set_target_app_bundle_id(Some("com.apple.Music".to_owned()))
            .unwrap();
        controller
            .set_scene_capturing(SceneHandle::new(55), true)
            .unwrap();
        controller.backend.available_processes.push(AudioProcessEntry {
            object_id: 88,
            pid: Some(880),
            bundle_id: Some("com.apple.Music".to_owned()),
        });
        assert!(
            !controller.handle_process_list_change().unwrap(),
            "background process events must never bypass permission"
        );
        assert!(!controller.is_capturing());

        controller.request_permission().unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        assert!(!controller.wants_process_list_watch());
        assert!(!controller.handle_process_list_change().unwrap());
    }

    #[test]
    fn failed_target_app_switch_rolls_back_backend_target_and_capture_state() {
        let mut backend = TargetAppBackend::default();
        backend.available_processes.push(AudioProcessEntry {
            object_id: 301,
            pid: Some(3010),
            bundle_id: Some("com.apple.Music".to_owned()),
        });
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller
            .set_scene_capturing(SceneHandle::new(71), true)
            .unwrap();
        assert!(controller.is_capturing());
        assert_eq!(controller.target_app_bundle_id(), None);
        assert!(!controller.wants_process_list_watch());

        // 1. Stop failure leaves previous target and running capture completely untouched.
        controller.backend.fail_stop = true;
        let stop_err = controller
            .set_target_app_bundle_id(Some("com.apple.Music".to_owned()))
            .unwrap_err();
        assert_eq!(stop_err, AudioCaptureError::Platform("target stop failed".into()));
        assert_eq!(controller.target_app_bundle_id(), None);
        assert!(controller.is_capturing());
        assert!(!controller.wants_process_list_watch());

        // 2. Start failure switching global -> per-app restores target=None and restarts global tap.
        controller.backend.fail_start_count = 1;
        let start_err = controller
            .set_target_app_bundle_id(Some("com.apple.Music".to_owned()))
            .unwrap_err();
        assert_eq!(start_err, AudioCaptureError::Platform("target start failed".into()));
        assert_eq!(controller.target_app_bundle_id(), None);
        assert!(controller.is_capturing());
        assert!(controller.backend().tapped_processes.is_empty());
        assert!(!controller.wants_process_list_watch());

        // 3. Start failure switching idle per-app -> global restores previous target and idle state.
        controller
            .set_target_app_bundle_id(Some("com.spotify.client".to_owned()))
            .unwrap();
        assert!(controller.is_idle_for_target());
        assert!(controller.wants_process_list_watch());
        controller.backend.fail_start_count = 1;
        let to_global_err = controller.set_target_app_bundle_id(None).unwrap_err();
        assert_eq!(to_global_err, AudioCaptureError::Platform("target start failed".into()));
        assert_eq!(controller.target_app_bundle_id(), Some("com.spotify.client"));
        assert!(controller.is_idle_for_target());
        assert!(!controller.is_capturing());
        assert!(controller.wants_process_list_watch());

        // 4. Double failure (new target start + rollback start both fail) still rolls back target
        //    and leaves restart_pending armed so a later restart_capture() heals capture.
        controller.set_target_app_bundle_id(None).unwrap();
        assert!(controller.is_capturing());
        controller.backend.fail_start_count = 2;
        let double_err = controller
            .set_target_app_bundle_id(Some("com.apple.Music".to_owned()))
            .unwrap_err();
        assert!(
            double_err.to_string().contains("rollback failed"),
            "double failure should surface both transition and rollback errors: {double_err}"
        );
        assert_eq!(controller.target_app_bundle_id(), None);
        assert!(!controller.wants_process_list_watch());
        assert!(!controller.is_capturing());
        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);
        assert!(controller.is_capturing());
    }

    #[test]
    fn failed_process_list_change_arms_restart_pending_for_recovery() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TargetAppBackend::default());
        controller
            .set_target_app_bundle_id(Some("com.spotify.client".to_owned()))
            .unwrap();
        controller
            .set_scene_capturing(SceneHandle::new(72), true)
            .unwrap();
        assert!(controller.is_idle_for_target());

        controller.backend.available_processes.push(AudioProcessEntry {
            object_id: 404,
            pid: Some(4040),
            bundle_id: Some("com.spotify.client".to_owned()),
        });
        controller.backend.fail_start_count = 1;
        assert!(controller.handle_process_list_change().is_err());
        assert!(!controller.is_capturing());
        assert!(controller.is_idle_for_target());

        // Recovery via restart_capture heals even without a second process-list notification.
        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);
        assert!(controller.is_capturing());
        assert!(!controller.is_idle_for_target());
        assert_eq!(controller.backend().tapped_processes, vec![404]);
    }
}
