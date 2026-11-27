import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import QuartzCore
import WallpaperMedia
import os

/// Whether a video player that cannot be heard (muted, at zero volume, muted by a rule or by Mute all
/// wallpapers, or a mirror member that does not carry its group's sound) leaves its sound undecoded and
/// its audio output stopped, rather than decoding it and playing it muted. The picture is the same
/// either way. On by default; `WALLPAPER_MACHINE_MUTED_VIDEO_AUDIO=1` plays the sound muted, as before,
/// for an A/B power comparison in one binary. Read once.
enum SilentVideoAudio {
  static let isReleased = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_MUTED_VIDEO_AUDIO"] != "1"
}

/// What a look at a WebM player's pipeline found, and what was done about it. The desktop surface
/// turns it into the health events the host logs and counts.
struct WebMHealthReport: Equatable {
  enum Verdict: Equatable {
    /// Frames were shown (or dropped on their deadline) and the clock moved.
    case advancing
    /// Something that should be moving was not; the text says what was seen.
    case stalled(String)
  }
  enum Repair: Equatable {
    case none
    /// The pipeline was flushed and fed again from where the clock is.
    case restarted
    /// Nothing left to try.
    case gaveUp
  }

  var trigger: String
  var verdict: Verdict
  var repair: Repair
  /// Whether this is the look that follows a repair, not the first look.
  var afterRepair = false
}

/// Plays a WebM or Matroska file with `AVSampleBufferDisplayLayer`: the project's own reader gives
/// compressed samples, the system decodes and shows them, and an `AVSampleBufferRenderSynchronizer`
/// keeps the picture and the sound on one clock. Decoding stays with the system's decoders (hardware,
/// including VP9 through VideoToolbox's supplemental decoder), so the process does no per-frame work
/// beyond handing the next compressed sample over.
///
/// - **Feeding** happens on a serial queue, from `requestMediaDataWhenReady`: a renderer that has room
///   asks for more and a sample goes in. Nothing runs while the renderer is full, and nothing runs
///   while the clock is stopped for long, because a stopped clock fills the renderers and stops the
///   requests.
/// - **Looping** is gapless by timestamps, not by seeking the player: at the end of the file the
///   reader goes back to the first key frame and its timestamps are raised by one duration, so the
///   clock runs on and no flush happens. The sound does the same and is cut where the picture ends.
/// - **Sound** is decoded to PCM by the reader (Opus, Vorbis, AAC, MP3) and played by an
///   `AVSampleBufferAudioRenderer` on the same synchronizer; without `withAudio` no audio is decoded,
///   no renderer is made and no audio session is touched, which is what the lock screen needs. While
///   the clip cannot be heard (muted or at zero volume) the sound is not decoded and the renderer is
///   off the clock, so no audio output runs for it; becoming audible feeds it again from the clock.
/// - **Placement** follows `NativeVideoLayout`, the rule the AVFoundation player and the scene engine
///   share, including the position, and the file's own orientation.
///
/// Compiled by the app and by the lock-screen extension.
@MainActor
final class WebMPlayer {
  /// Frames-per-second below which a clip is not judged by how often it feeds the renderer.
  static let healthWindowSeconds = 2.0
  static let healthWindow = Duration.seconds(healthWindowSeconds)
  /// The renderer's notifications, by name: Swift's own spellings of them are deprecated in the newest
  /// SDK in favour of an API that needs macOS 27.
  private static let didFailToDecode = Notification.Name("AVSampleBufferVideoRendererDidFailToDecodeNotification")
  private static let didFailToDecodeErrorKey = "AVSampleBufferVideoRendererDidFailToDecodeNotificationErrorKey"
  private static let requiresFlushDidChange = Notification.Name(
    "AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification")
  static let healthSettle = Duration.milliseconds(500)
  /// How long a stopped player must have been paused before resuming it is worth a health check.
  static let minimumPauseForCheck = Duration.seconds(5)

  let file: WebMFile
  /// The layer the picture is drawn on. Put it somewhere with `attach(to:)`.
  let layer = AVSampleBufferDisplayLayer()

  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let audioRenderer: AVSampleBufferAudioRenderer?
  private let feeder: WebMFeeder
  private let queue: DispatchQueue
  private let now: @MainActor () -> ContinuousClock.Instant
  private let sleep: @Sendable (Duration) async throws -> Void
  private var recovery: NativeVideoRecoveryBudget

  private var started = false
  private var stopped = false
  private var paused: Bool
  private var pausedSince: ContinuousClock.Instant?
  private var failureLatched = false
  private var hasShownFrame = false
  private var audioActive: Bool
  /// Whether the sound can be heard: not muted and above zero volume.
  private var audible = true
  /// Whether the audio renderer is on the synchronizer's clock.
  private var audioOnClock = false
  /// Removals from the clock the synchronizer has not finished, and whether the renderer goes back
  /// on once they have.
  private var pendingAudioRemovals = 0
  private var audioAddAwaitsRemoval = false
  private let releasesSilentAudio: Bool
  private var observers: [NSObjectProtocol] = []
  private var statusObservation: NSKeyValueObservation?
  private var healthTask: Task<Void, Never>?
  private var decodeFailures = 0
  private var firstDecodeFailure: String?
  // Repositioning the readers happens on the feed queue and never blocks the main actor: a read
  // from a volume that has stopped answering would freeze the app. `feedEpoch` retires the
  // repositionings that are in flight when the player stops or fails.
  private var feedEpoch = 0
  private var repositioning = 0
  private var restartAfterReposition = false
  /// Target clock time held paused during an async live `setLoopRange` reposition so the clock
  /// cannot advance or play stale buffers before the readers finish seeking.
  private var pendingClockResetTime: CMTime?
  /// True when a pre-start `setLoopRange` skipped audio repositioning because audio was silent.
  private var audioNeedsRepositionOnStart = false
  /// Who waits for the clip to start over (`watchNextLoop`), and the synchronizer's boundary
  /// observer at the end of the pass the clock is in. Both exist only while someone waits.
  private var loopWatch: (@MainActor () -> Void)?
  private var loopBoundary: Any?
  /// Tells a crossing already on its way to the main queue for a watch that was replaced meanwhile.
  private var loopWatchSerial: UInt64 = 0

  // Placement.
  private var mode: NativeVideoScalingMode = .fill
  private var factor = 1.0
  private var pan = NativeVideoLayout.Pan.centered
  private var viewport = CGRect.zero
  private var backingScale: CGFloat = 1
  /// Optional multi-display span viewport frames (`media` = aspect-filled virtual canvas in this
  /// display's local y-up coordinates). `nil` uses standard `NativeVideoLayout`.
  private var spanMediaFrame: CGRect?
  /// Optional A–B loop trim interval in seconds relative to `file.firstPresentationTime`.
  private var loopRange: ClosedRange<Double>?
  /// Wallpaper Engine's per-wallpaper options: the clock's rate (`rate` / 100, WE
  /// `sub_1400FFCB0`), the horizontal flip, the Fit-style border colour and the colour pipeline,
  /// whose filtered feed runs only while it changes the picture.
  private var playRate: Float = 1
  private var flipHorizontal = false
  private var borderColor: CGColor?
  private weak var root: CALayer?
  private let colorPipeline = VideoColorPipeline()
  private var filteredSink: WebMFilteredVideoSink?

  /// Why the file's sound is not played, when the file has some and it cannot be: the codec is not
  /// decodable, the reader refused the track. nil when it plays, or when none was asked for.
  private(set) var audioUnavailableReason: String?

  /// Called once with the reason when the clip can no longer be played: the system's decoder refused
  /// it, or the pipeline stopped delivering and repairs did not bring it back. The second argument
  /// says whether the failure is a verdict on the file (a decoder that never opened it) and not on
  /// the moment (a pipeline the system took away while the Mac slept). A failure that arrives with
  /// no handler is held and delivered when one is set.
  var onFailure: ((String, Bool) -> Void)? {
    didSet { deliverPendingFailure() }
  }
  private var pendingFailure: (detail: String, settled: Bool)?
  /// The sound failed and the clip goes on without it.
  var onAudioDropped: ((String) -> Void)?
  /// The first picture is on the layer.
  var onReadyForDisplay: (() -> Void)? {
    didSet { if isReadyForDisplay { onReadyForDisplay?() } }
  }
  var onHealthReport: ((WebMHealthReport) -> Void)?

  /// The clock the picture and the sound follow. Runs on past the file's end at every loop.
  var currentTime: CMTime { synchronizer.currentTime() }
  var videoSamplesFed: UInt64 { feeder.videoSamplesEnqueued }
  var audioBuffersFed: UInt64 { feeder.audioBuffersEnqueued }
  var isReadyForDisplay: Bool { !stopped && layer.isReadyForDisplay }
  var isPlaying: Bool { started && !stopped && !failureLatched && !paused }

  init(
    file: WebMFile, withAudio: Bool, paused: Bool,
    loopRange: ClosedRange<Double>? = nil,
    recovery: NativeVideoRecoveryBudget.Policy = .init(),
    feedQueue: DispatchQueue = DispatchQueue(label: "app.wallpapermachine.webm-feed", qos: .userInitiated),
    now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    releasesSilentAudio: Bool = SilentVideoAudio.isReleased
  ) {
    self.file = file
    self.paused = paused
    self.loopRange = loopRange
    self.releasesSilentAudio = releasesSilentAudio
    self.recovery = NativeVideoRecoveryBudget(policy: recovery)
    self.queue = feedQueue
    self.now = now
    self.sleep = sleep

    var audioReader: WebMAudioReader?
    if withAudio {
      if file.hasPlayableAudio {
        do { audioReader = try file.makeAudioReader() } catch {
          audioUnavailableReason = error.localizedDescription
        }
      } else if let reason = file.audioUnavailableReason {
        audioUnavailableReason = reason
      }
    }
    audioRenderer = audioReader == nil ? nil : AVSampleBufferAudioRenderer()
    audioActive = audioReader != nil
    feeder = WebMFeeder(file: file, audio: audioReader, loopRange: loopRange)

    layer.videoGravity = .resizeAspectFill
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    synchronizer.addRenderer(layer.sampleBufferRenderer)
    if let audioRenderer {
      synchronizer.addRenderer(audioRenderer)
      audioOnClock = true
    }
    let window = WebMFeeder.effectiveWindow(in: file, loopRange: loopRange)
    synchronizer.setRate(0, time: window.start)
    feeder.onFailure = { [weak self] detail in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(detail, settled: false) } }
    }
    feeder.onAudioFailure = { [weak self] detail in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.dropAudio(detail) } }
    }
    observe()
  }

  // MARK: - Layer and placement

  /// Puts the layer into `root`, whose bounds are the display. The overflow of Fill, Original size and
  /// a large scale factor is cropped there.
  func attach(to root: CALayer) {
    root.masksToBounds = true
    root.addSublayer(layer)
    self.root = root
    applyPlacement()
  }

  func relayout(bounds: CGRect, backingScale: CGFloat) {
    viewport = bounds
    self.backingScale = backingScale
    applyPlacement()
  }

  func setScaling(_ mode: NativeVideoScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {
    self.mode = mode
    self.factor = factor
    self.pan = pan
    applyPlacement()
  }

  /// Positions the layer to slice a multi-display spanned virtual canvas (`mediaFrameInDisplay` in
  /// this display's local y-up layer coordinates).
  func setSpanMediaFrame(_ mediaFrameInDisplay: CGRect?) {
    guard spanMediaFrame != mediaFrameInDisplay else { return }
    spanMediaFrame = mediaFrameInDisplay
    applyPlacement()
  }

  /// Updates or clears the A–B loop trim interval (`start...end`, seconds from clip start) live
  /// without tearing down the player or blocking the main actor.
  func setLoopRange(_ range: ClosedRange<Double>?) {
    guard !stopped, range != loopRange else { return }
    loopRange = range
    let window = WebMFeeder.effectiveWindow(in: file, loopRange: range)
    guard started else {
      synchronizer.setRate(0, time: window.start)
      let feeder = self.feeder
      let moveAudio = feedsAudio
      audioNeedsRepositionOnStart = audioActive && !moveAudio
      queue.async {
        feeder.setLoopRange(range)
        feeder.reposition(at: window.start, audio: moveAudio)
      }
      return
    }
    guard !failureLatched else { return }
    stopFeeding()
    // Pause the clock at the new window start and flush stale buffers immediately so old audio
    // and video cannot play and the clock cannot advance while the feed queue repositions. The
    // running rate is restored inside `repositioned(_:)` once repositioning completes.
    synchronizer.setRate(0, time: window.start)
    layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    audioRenderer?.flush()
    pendingClockResetTime = window.start
    if let watch = loopWatch { _ = watchNextLoop(watch) }
    restartAfterReposition = true
    reposition(video: true, at: window.start, updatingLoopRange: range)
  }

  var loopRangeForTest: ClosedRange<Double>? { loopRange }
  var synchronizerRateForTest: Float { synchronizer.rate }
  var isFlippedHorizontally: Bool { flipHorizontal }

  private func applyPlacement() {
    guard !stopped else { return }
    let size = file.presentationSize
    let upright = file.preferredTransform.isIdentity
    if let target = spanMediaFrame {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      let stored = !upright && file.transformSwapsAxes ? CGSize(width: target.height, height: target.width) : target.size
      layer.videoGravity = .resize
      layer.setAffineTransform(.identity)
      layer.bounds = CGRect(origin: .zero, size: stored)
      layer.position = CGPoint(x: target.midX, y: target.midY)
      layer.setAffineTransform((upright ? .identity : file.layerTransform).concatenating(mirror))
      root?.backgroundColor = CGColor(gray: 0, alpha: 1)
      return
    }
    var placement = NativeVideoLayout.placement(
      mode: mode, factor: factor, videoSize: size, viewport: viewport.size,
      backingScale: backingScale, pan: pan)
    if !upright, case .gravity = placement {
      // Gravity centres the stored picture before the turn, so a turned clip is placed by its frame.
      let rect = NativeVideoLayout.pictureRect(
        mode: mode, factor: factor, videoSize: size, viewport: viewport.size,
        backingScale: backingScale, pan: pan)
      let scale = CGFloat(NativeVideoLayout.normalizedFactor(Double(backingScale)))
      placement = .frame(
        CGRect(
          x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale, width: CGFloat(rect.width) / scale,
          height: CGFloat(rect.height) / scale))
    }
    // A sliding picture would show the layout settling.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    switch placement {
    case .gravity(let gravity):
      layer.setAffineTransform(.identity)
      layer.videoGravity = gravity
      layer.bounds = CGRect(origin: .zero, size: viewport.size)
      layer.position = CGPoint(x: viewport.midX, y: viewport.midY)
      layer.setAffineTransform(mirror)
    case .frame(let rect):
      // The rectangle already has the picture's own aspect, so nothing but a plain stretch may
      // apply another aspect rule to it.
      layer.videoGravity = .resize
      // The layout measures from the top edge and the container's layer grows upward.
      let target = NativeVideoLayout.layerFrame(rect, viewportHeight: viewport.height)
        .offsetBy(dx: viewport.minX, dy: viewport.minY)
      // The layer keeps the stored shape and is turned about its centre onto the target; the
      // flip mirrors the shown picture after the turn.
      let stored = !upright && file.transformSwapsAxes ? CGSize(width: target.height, height: target.width) : target.size
      layer.setAffineTransform(.identity)
      layer.bounds = CGRect(origin: .zero, size: stored)
      layer.position = CGPoint(x: target.midX, y: target.midY)
      layer.setAffineTransform((upright ? .identity : file.layerTransform).concatenating(mirror))
    case .pending:
      break
    }
    let fitStyle = mode != .fill && mode != .fillBlurred && mode != .stretch
    root?.backgroundColor = (fitStyle ? borderColor : nil) ?? CGColor(gray: 0, alpha: 1)
  }

  private var mirror: CGAffineTransform { flipHorizontal ? CGAffineTransform(scaleX: -1, y: 1) : .identity }

  /// Applies Wallpaper Engine's options. Switching the colour pipeline on or off rebuilds the
  /// feed from the clock (not a repair: no recovery allowance is spent).
  func setEngineOptions(_ options: WallpaperEngineOptions, lut: VideoLut?, borderColor: CGColor?) {
    let rate = Float(max(10, min(options.playbackRate, 200)) / 100)
    if rate != playRate {
      playRate = rate
      if started, !paused, !stopped, pendingClockResetTime == nil { synchronizer.rate = rate }
    }
    let parameters = VideoColorPipeline.Parameters(options: options, lut: lut)
    let wasFiltered = filteredSink != nil
    colorPipeline.update(parameters)
    flipHorizontal = options.flipHorizontal
    self.borderColor = borderColor
    applyPlacement()
    let filtered = VideoColorPipeline.needsComposition(parameters)
    guard filtered != wasFiltered else { return }
    if filtered {
      let sink = WebMFilteredVideoSink(output: layer.sampleBufferRenderer, pipeline: colorPipeline)
      sink.onFailure = { [weak self, weak sink] error in
        let detail = error.localizedDescription
        Task { @MainActor in
          guard let self, let sink, self.filteredSink === sink, !self.stopped else { return }
          if self.hasShownFrame, self.restartPlayback(reason: detail) { return }
          // A failure in the optional filtering path does not condemn the source file.
          self.fail(detail, settled: false)
        }
      }
      filteredSink = sink
    } else {
      filteredSink = nil
    }
    if started, !stopped, !failureLatched { rebuild() }
  }

  var rateForTest: Float { playRate }
  var feedsFilteredForTest: Bool { filteredSink != nil }
  var layerTransformForTest: CGAffineTransform { layer.affineTransform() }

  // MARK: - Sound

  /// The volume and mute. A clip that cannot be heard stops asking for sound and its audio renderer
  /// leaves the clock, so nothing decodes it and no audio output runs; the picture and the clock are
  /// untouched. Becoming audible moves the sound to where the clock is and feeds it again, the way a
  /// flush the system made is recovered.
  func setVolume(_ volume: Float, muted: Bool) {
    guard let audioRenderer, audioActive else { return }
    audioRenderer.volume = max(0, min(1, volume))
    audioRenderer.isMuted = muted
    let audible = !muted && volume > 0
    guard audible != self.audible else { return }
    self.audible = audible
    guard releasesSilentAudio, !stopped else { return }
    if audible {
      // Before `start`, reposition audio only if a pre-start `setLoopRange` skipped it while muted.
      if !started {
        if audioNeedsRepositionOnStart {
          audioNeedsRepositionOnStart = false
          let window = WebMFeeder.effectiveWindow(in: file, loopRange: loopRange)
          let feeder = self.feeder
          queue.async { feeder.repositionAudio(at: window.start) }
        }
        return
      }
      guard !failureLatched else { return }
      let time = synchronizer.currentTime()
      reposition(video: false, at: time.isNumeric ? time : file.firstPresentationTime)
    } else {
      audioRenderer.stopRequestingMediaData()
      takeAudioOffClock(audioRenderer)
    }
  }

  /// Whether the sound is to be decoded and fed: it plays, and it can be heard or the A/B switch keeps
  /// a silent one running.
  private var feedsAudio: Bool { audioActive && (audible || !releasesSilentAudio) }

  private func takeAudioOffClock(_ audioRenderer: AVSampleBufferAudioRenderer) {
    guard audioOnClock else { return }
    audioOnClock = false
    audioAddAwaitsRemoval = false
    pendingAudioRemovals += 1
    synchronizer.removeRenderer(audioRenderer, at: .invalid) { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioRemovalFinished(audioRenderer) } }
    }
  }

  /// The synchronizer finished taking the renderer off its clock. An unmute that came while it was
  /// still doing so adds it back now: added earlier, the removal would have taken it off again.
  private func audioRemovalFinished(_ audioRenderer: AVSampleBufferAudioRenderer) {
    pendingAudioRemovals -= 1
    guard pendingAudioRemovals == 0, audioAddAwaitsRemoval else { return }
    audioAddAwaitsRemoval = false
    guard !stopped, audioOnClock else { return }
    synchronizer.addRenderer(audioRenderer)
  }

  /// Puts the audio renderer back on the clock, emptied of what it held from before it left: that is
  /// behind the clock now. Called only where nothing is feeding it.
  private func putAudioOnClock(_ audioRenderer: AVSampleBufferAudioRenderer) {
    guard !audioOnClock else { return }
    audioOnClock = true
    audioRenderer.flush()
    if pendingAudioRemovals > 0 {
      audioAddAwaitsRemoval = true
      return
    }
    synchronizer.addRenderer(audioRenderer)
  }

  var isAudioOnClockForTest: Bool { audioOnClock }
  var audioFedFromForTest: CMTime { feeder.audioFedFromSinceMove }
  /// Sends the sound to an output that does not exist, so a test never reaches a real one.
  func setAudioOutputDeviceForTest(_ uniqueID: String) { audioRenderer?.audioOutputDeviceUniqueID = uniqueID }

  private func dropAudio(_ detail: String) {
    guard !stopped, audioActive, let audioRenderer else { return }
    audioActive = false
    audioRenderer.stopRequestingMediaData()
    takeAudioOffClock(audioRenderer)
    audioUnavailableReason = detail
    onAudioDropped?(detail)
  }

  // MARK: - Running

  /// Begins feeding and, unless paused, the clock. Call once.
  func start() {
    guard !started, !stopped else { return }
    started = true
    startFeeding()
    let window = WebMFeeder.effectiveWindow(in: file, loopRange: loopRange)
    synchronizer.setRate(paused ? 0 : playRate, time: window.start)
    if paused { pausedSince = now() }
  }

  /// Plays or holds the clip. A held clip keeps its last picture on the layer and decodes nothing:
  /// its renderers fill and stop asking for samples.
  func setPaused(_ value: Bool) {
    guard !stopped, value != paused else { return }
    paused = value
    guard started else { return }
    if value {
      pausedSince = now()
      synchronizer.rate = 0
      healthTask?.cancel()
      healthTask = nil
    } else {
      if pendingClockResetTime == nil { synchronizer.rate = playRate }
      if let since = pausedSince, now() - since >= Self.minimumPauseForCheck {
        verifyPlayback(reason: "resumed after \(Int((now() - since) / .seconds(1))) s")
      }
      pausedSince = nil
    }
  }

  /// Calls `handler` once, when the clock reaches the end of the pass it is in and the clip
  /// starts over. The synchronizer reports that crossing itself, so nothing is sampled, and a
  /// held clock crosses nothing. False for a still picture and for a player that has not
  /// started, has stopped or has failed. A later call replaces the earlier watch.
  func watchNextLoop(_ handler: @escaping @MainActor () -> Void) -> Bool {
    guard started, !stopped, !failureLatched,
      let end = WebMFeeder.endOfPass(containing: synchronizer.currentTime(), in: file, loopRange: loopRange)
    else { return false }
    cancelLoopWatch()
    loopWatchSerial &+= 1
    let serial = loopWatchSerial
    loopWatch = handler
    loopBoundary = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) {
      [weak self] in
      MainActor.assumeIsolated { self?.loopBoundaryCrossed(serial: serial) }
    }
    return true
  }

  func cancelLoopWatch() {
    if let loopBoundary { synchronizer.removeTimeObserver(loopBoundary) }
    loopBoundary = nil
    loopWatch = nil
  }

  private func loopBoundaryCrossed(serial: UInt64) {
    guard !stopped, serial == loopWatchSerial, let handler = loopWatch else { return }
    cancelLoopWatch()
    handler()
  }

  func stop() {
    guard !stopped else { return }
    cancelLoopWatch()
    stopped = true
    healthTask?.cancel()
    healthTask = nil
    pendingFailure = nil
    onFailure = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    statusObservation = nil
    abandonFeeding()
    synchronizer.rate = 0
    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    audioRenderer?.flush()
    layer.removeFromSuperlayer()
    // The readers go once the queue has finished what it is doing; a read that hangs holds that
    // queue, not the caller.
    let feeder = self.feeder
    filteredSink = nil
    queue.async { feeder.release() }
  }

  private func startFeeding() {
    let feeder = self.feeder
    let video = layer.sampleBufferRenderer
    let filtered = filteredSink
    let sink: WebMSampleSink = filtered ?? video
    video.requestMediaDataWhenReady(on: queue) { [video, sink, filtered] in
      if !feeder.feedVideo(into: sink) || filtered?.hasFailed == true { video.stopRequestingMediaData() }
    }
    if let audioRenderer, feedsAudio {
      putAudioOnClock(audioRenderer)
      startFeedingAudio(into: audioRenderer)
    }
  }

  private func startFeedingAudio(into audioRenderer: AVSampleBufferAudioRenderer) {
    let feeder = self.feeder
    audioRenderer.requestMediaDataWhenReady(on: queue) { [audioRenderer] in
      if !feeder.feedAudio(into: audioRenderer) { audioRenderer.stopRequestingMediaData() }
    }
  }

  /// Stops asking the renderers for samples. A feed callback that is already running finishes on
  /// the queue; nothing here waits for it.
  private func stopFeeding() {
    layer.sampleBufferRenderer.stopRequestingMediaData()
    audioRenderer?.stopRequestingMediaData()
  }

  /// Stops feeding for good and retires every repositioning still in flight.
  private func abandonFeeding() {
    stopFeeding()
    feedEpoch += 1
    repositioning = 0
    restartAfterReposition = false
    pendingClockResetTime = nil
  }

  /// Moves the readers on the feed queue, behind any feed callback already running there, and
  /// resumes feeding on the main actor once the last repositioning in flight is done.
  private func reposition(video: Bool, at time: CMTime, updatingLoopRange newRange: ClosedRange<Double>?? = nil) {
    repositioning += 1
    let feeder = self.feeder
    let filtered = filteredSink
    let epoch = feedEpoch
    // A sound nobody hears is not decoded up to the clock; it is moved there when it is heard again.
    let audio = feedsAudio
    queue.async { [weak self] in
      if let newRange { feeder.setLoopRange(newRange) }
      if video {
        filtered?.reset()
        feeder.reposition(at: time, audio: audio)
      } else { feeder.repositionAudio(at: time) }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.repositioned(epoch) } }
    }
  }

  private func repositioned(_ epoch: Int) {
    guard !stopped, !failureLatched, epoch == feedEpoch else { return }
    repositioning -= 1
    guard repositioning == 0 else { return }
    if restartAfterReposition {
      restartAfterReposition = false
      // Everything a feed callback put in before the readers moved is flushed away here, behind
      // the queue's barrier, and the renderers are fed again from the new position.
      layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
      audioRenderer?.flush()
      decodeFailures = 0
      startFeeding()
      if let resetTime = pendingClockResetTime {
        pendingClockResetTime = nil
        synchronizer.setRate(paused ? 0 : playRate, time: resetTime)
        if let watch = loopWatch { _ = watchNextLoop(watch) }
      }
    } else if let audioRenderer, feedsAudio {
      putAudioOnClock(audioRenderer)
      startFeedingAudio(into: audioRenderer)
    }
  }

  // MARK: - Failure and repair

  private func fail(_ detail: String, settled: Bool) {
    guard !stopped, !failureLatched else { return }
    failureLatched = true
    healthTask?.cancel()
    healthTask = nil
    pendingFailure = (detail, settled)
    abandonFeeding()
    synchronizer.rate = 0
    deliverPendingFailure()
  }

  private func deliverPendingFailure() {
    guard !stopped, let pending = pendingFailure, let handler = onFailure else { return }
    pendingFailure = nil
    handler(pending.detail, pending.settled)
  }

  /// Rebuilds the feed from where the clock is: renderers flushed, readers moved to the key frame
  /// before that time and the sound to the time itself. The clock is not touched, so frames before
  /// the time are decoded and dropped as late and the picture resumes where it was. False when the
  /// allowance for repairs is spent.
  @discardableResult
  func restartPlayback(reason: String) -> Bool {
    guard !stopped, !failureLatched, started, recovery.permit(at: now()) else { return false }
    rebuild()
    return true
  }

  private func rebuild() {
    let time = synchronizer.currentTime()
    stopFeeding()
    restartAfterReposition = true
    reposition(video: true, at: time.isNumeric ? time : file.firstPresentationTime)
  }

  private func observe() {
    let center = NotificationCenter.default
    let renderer = layer.sampleBufferRenderer
    observers.append(
      center.addObserver(
        forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.readyForDisplayChanged() }
      })
    observers.append(
      center.addObserver(
        forName: Self.didFailToDecode, object: renderer, queue: .main
      ) { [weak self] note in
        let error = note.userInfo?[Self.didFailToDecodeErrorKey] as? NSError
        MainActor.assumeIsolated { self?.decodeFailed(error) }
      })
    observers.append(
      center.addObserver(
        forName: Self.requiresFlushDidChange, object: renderer, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.requiresFlushChanged() }
      })
    if let audioRenderer {
      observers.append(
        center.addObserver(
          forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: audioRenderer,
          queue: .main
        ) { [weak self] note in
          let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
          MainActor.assumeIsolated { self?.audioFlushed(at: time) }
        })
    }
    statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
      guard renderer.status == .failed else { return }
      let detail = renderer.error?.localizedDescription ?? "the video renderer failed"
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.rendererFailed(detail) } }
    }
  }

  private func readyForDisplayChanged() {
    guard !stopped, layer.isReadyForDisplay else { return }
    hasShownFrame = true
    recovery.healthy(at: now())
    onReadyForDisplay?()
  }

  private func decodeFailed(_ error: NSError?) {
    guard !stopped else { return }
    decodeFailures += 1
    if firstDecodeFailure == nil { firstDecodeFailure = error?.localizedDescription ?? "a frame could not be decoded" }
    // A decoder that fails every frame from the first one never opened the track: that is the
    // file's verdict. A frame lost in the middle of a playing clip is a glitch.
    if !hasShownFrame, decodeFailures >= 3 {
      fail("the system could not decode the video: \(firstDecodeFailure ?? "unknown error")", settled: true)
    }
  }

  private func requiresFlushChanged() {
    guard !stopped, !failureLatched, layer.sampleBufferRenderer.requiresFlushToResumeDecoding else { return }
    // The system took the decoder back (a sleep, a session change); decoding resumes after a flush.
    if !restartPlayback(reason: "the renderer asked to be flushed") {
      fail("the video decoder was taken away and could not be restored", settled: false)
    }
  }

  private func rendererFailed(_ detail: String) {
    guard !stopped, !failureLatched else { return }
    if hasShownFrame, restartPlayback(reason: detail) { return }
    fail(detail, settled: !hasShownFrame)
  }

  /// The system flushed the sound by itself (the output device changed): feed it again from where it
  /// was flushed.
  private func audioFlushed(at time: CMTime?) {
    // A renderer off the clock is flushed and fed from the clock when it goes back on.
    guard !stopped, !failureLatched, feedsAudio, audioOnClock, let audioRenderer else { return }
    let at = time ?? synchronizer.currentTime()
    audioRenderer.stopRequestingMediaData()
    reposition(video: false, at: at.isNumeric ? at : file.firstPresentationTime)
  }

  // MARK: - Health

  /// Looks, after a short settle, at whether pictures still come out, and repairs the pipeline if they
  /// do not: for a reason the player cannot see itself (the Mac or its displays woke, the session came
  /// back, a long pause ended). A pipeline that is paused, was never shown or belongs to a single
  /// still picture is not judged.
  func verifyPlayback(reason: String) {
    guard started, !stopped, !failureLatched, !paused, hasShownFrame, file.frameCount > 1 else { return }
    healthTask?.cancel()
    let sleep = self.sleep
    healthTask = Task { @MainActor [weak self] in
      do { try await sleep(Self.healthSettle) } catch { return }
      guard let self else { return }
      await self.judge(trigger: reason, afterRepair: false)
    }
  }

  /// One look: the clock and the renderer's frame count, `healthWindow` apart.
  private func judge(trigger: String, afterRepair: Bool) async {
    guard !stopped, !failureLatched, !paused else { return }
    let before = await sample()
    do { try await sleep(afterRepair ? Self.healthWindow * 2 : Self.healthWindow) } catch { return }
    guard !stopped, !failureLatched, !paused, !Task.isCancelled else { return }
    let after = await sample()
    guard let before, let after else {
      // The system gave no frame counts: the clock alone cannot show a decoder alive.
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .advancing, repair: .none, afterRepair: afterRepair))
      return
    }
    let clock = (after.time - before.time).seconds
    let frames = after.frames - before.frames
    if clock >= 0.5 * Self.healthWindowSeconds, frames > 0 {
      recovery.healthy(at: now())
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .advancing, repair: .none, afterRepair: afterRepair))
      return
    }
    let detail = "the clock moved \(String(format: "%.1f", clock)) s and \(frames) frames were shown or dropped"
    if !afterRepair, restartPlayback(reason: detail) {
      onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .stalled(detail), repair: .restarted, afterRepair: afterRepair))
      await judge(trigger: trigger, afterRepair: true)
      return
    }
    onHealthReport?(WebMHealthReport(trigger: trigger, verdict: .stalled(detail), repair: .gaveUp, afterRepair: afterRepair))
    fail("playback did not advance (\(detail))", settled: false)
  }

  private struct Sample {
    var time: CMTime
    var frames: Int
  }

  private func sample() async -> Sample? {
    let metrics = await layer.sampleBufferRenderer.videoPerformanceMetrics
    guard let metrics else { return nil }
    return Sample(time: synchronizer.currentTime(), frames: metrics.totalNumberOfFrames)
  }

  /// Where the pipeline stands, in one line for the log.
  var stateSummary: String {
    let renderer = layer.sampleBufferRenderer
    let status: String
    switch renderer.status {
    case .unknown: status = "unknown"
    case .rendering: status = "rendering"
    case .failed: status = "failed (\(renderer.error?.localizedDescription ?? "no error"))"
    @unknown default: status = "?"
    }
    let time = synchronizer.currentTime()
    return
      "renderer \(status), ready for display \(layer.isReadyForDisplay), clock "
      + "\(String(format: "%.2f", time.isNumeric ? time.seconds : -1)) s at rate \(synchronizer.rate), "
      + "\(feeder.videoSamplesEnqueued) samples fed, \(decodeFailures) decode failures"
  }

  // MARK: - Poster

  /// The picture on the display now, upright at the clip's shown size, decoded from the key frame at
  /// or before the clock. Decoded once for this request; nothing runs between requests.
  func posterImage() async -> CGImage? {
    await decodePoster(applyFlip: true)
  }

  /// Same as `posterImage()`, without horizontal mirroring so a multi-display span can mirror
  /// across the full virtual union canvas instead of each display separately.
  func unflippedPosterImage() async -> CGImage? {
    await decodePoster(applyFlip: false)
  }

  private func decodePoster(applyFlip: Bool) async -> CGImage? {
    guard !stopped else { return nil }
    let window = WebMFeeder.effectiveWindow(in: file, loopRange: loopRange)
    let time = started ? synchronizer.currentTime() : window.start
    let first = window.start
    let length = window.length
    // The clock runs on past the pass's end at every loop; the picture is the one at the same point
    // of the pass.
    var inPass = time
    if time.isNumeric, length.isNumeric, length.seconds > 0, time >= first {
      let passes = floor((time - first).seconds / length.seconds)
      inPass = CMTimeSubtract(time, CMTimeMultiplyByFloat64(length, multiplier: passes))
    }
    let file = self.file
    let pipeline = colorPipeline
    let flip = applyFlip && flipHorizontal
    return await Task.detached(priority: .utility) { () -> CGImage? in
      guard var image = file.copyPosterImage(at: inPass) else { return nil }
      // The poster shows what the layer shows: the colour options, then the flip.
      if VideoColorPipeline.needsComposition(pipeline.current) || flip {
        guard var picture = try? pipeline.apply(to: CIImage(cgImage: image)) else { return nil }
        if flip {
          picture = picture.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
            .translatedBy(x: -picture.extent.width, y: 0))
        }
        guard let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(picture, from: picture.extent) else { return nil }
        image = rendered
      }
      return image
    }.value
  }
}

// MARK: - Feeding

/// Where the feeder puts samples: a renderer, or a recording stand-in in a test.
protocol WebMSampleSink: AnyObject {
  /// The sink can take another sample now.
  var hasRoom: Bool { get }
  func accept(_ buffer: CMSampleBuffer)
}

extension AVSampleBufferVideoRenderer: WebMSampleSink {
  var hasRoom: Bool { isReadyForMoreMediaData }
  func accept(_ buffer: CMSampleBuffer) { enqueue(buffer) }
}

extension AVSampleBufferAudioRenderer: WebMSampleSink {
  var hasRoom: Bool { isReadyForMoreMediaData }
  func accept(_ buffer: CMSampleBuffer) { enqueue(buffer) }
}

/// Hands the readers' samples to the renderers, and wraps them at the end of the file (or at the
/// end of an optional A–B `loopRange`). Every method runs on the player's feed queue, never two at
/// once; the main actor never waits for it.
final class WebMFeeder: @unchecked Sendable {
  /// Minimum A–B loop duration, in seconds, matching `VideoTrimRange.minimumDuration`.
  static let minimumLoopDuration: Double = 0.5
  private static let durationTolerance: Double = 1e-9

  /// The effective loop pass boundaries on the file's own timeline (`[start, end)`).
  struct EffectiveLoopWindow: Equatable {
    var start: CMTime
    var end: CMTime
    var length: CMTime
    var isTrimmed: Bool
  }

  private let file: WebMFile
  private var video: WebMVideoReader?
  private var audio: WebMAudioReader?
  private let first: CMTime
  private let length: CMTime
  private let loops: Bool
  private var window: EffectiveLoopWindow
  private var videoPass = 0
  private var audioPass = 0
  private var videoDone = false
  private var audioDone = false
  /// Base timestamp offset applied across passes after an empty-window fallback so timestamps
  /// keep advancing monotonically from where preroll left off.
  private var baseTimeOffset: CMTime = .zero
  /// Highest DTS emitted in trimmed mode so reordered B-frame clips never emit a backward DTS.
  private var lastTrimmedVideoDTS: CMTime = .invalid
  /// True when the current trimmed pass started from `window.start` (not a mid-pass reposition),
  /// so finishing it with zero visible frames proves the window itself contains no visible frames.
  private var startedPassAtWindowStart = true
  /// Set when a trimmed pass wraps so the first sample of the new pass signals the decoder to
  /// reset its reference chain cleanly before decoding from the rewound keyframe.
  private var needsResetDecoder = false
  /// Tracks whether the current trimmed pass emitted at least one visible frame, preventing an
  /// infinite wrap loop on degenerate files whose timestamps never fall inside the requested window.
  private var emittedVisibleInPass = false
  /// Audio buffers decoded to reach a time after a reposition, ahead of the reader's next.
  private var heldAudio: CMSampleBuffer?
  private let counters = OSAllocatedUnfairLock(initialState: UInt64(0))
  /// Audio buffers handed over, and the time of the first one since the sound was last moved.
  private struct AudioFed {
    var buffers: UInt64 = 0
    var firstSinceMove = CMTime.invalid
  }
  private let audioFed = OSAllocatedUnfairLock(initialState: AudioFed())

  var onFailure: (@Sendable (String) -> Void)?
  var onAudioFailure: (@Sendable (String) -> Void)?

  init(file: WebMFile, audio: WebMAudioReader?, loopRange: ClosedRange<Double>? = nil) {
    self.file = file
    self.video = file.makeVideoReader()
    self.audio = audio
    first = file.firstPresentationTime
    length = file.duration
    loops = Self.loops(file)
    window = Self.effectiveWindow(in: file, loopRange: loopRange)
    if window.isTrimmed {
      needsResetDecoder = true
      _ = video?.seek(to: window.start)
      rewindAudioForPass(0, advanceTo: window.start)
    } else {
      audio?.rewind(withTimeOffset: .zero, limit: loops ? length : .invalid)
    }
  }

  /// Computes the clamped loop window for `file` and optional `loopRange` (`start...end`, seconds
  /// relative to `file.firstPresentationTime`). Falls back to the full clip whenever the range is
  /// nil, malformed, out of bounds, or leaves less than `minimumLoopDuration` inside the file.
  static func effectiveWindow(in file: WebMFile, loopRange: ClosedRange<Double>?) -> EffectiveLoopWindow {
    let full = EffectiveLoopWindow(
      start: file.firstPresentationTime,
      end: CMTimeAdd(file.firstPresentationTime, file.duration),
      length: file.duration,
      isTrimmed: false)
    guard loops(file), let range = loopRange else { return full }
    let startSeconds = range.lowerBound
    let endSeconds = range.upperBound
    let totalSeconds = file.duration.seconds
    guard startSeconds.isFinite, endSeconds.isFinite, totalSeconds.isFinite,
          startSeconds >= 0, endSeconds > startSeconds,
          startSeconds < totalSeconds, endSeconds > 0
    else { return full }
    let clampedStart = max(0, startSeconds)
    let clampedEnd = min(totalSeconds, endSeconds)
    guard (clampedEnd - clampedStart) + durationTolerance >= minimumLoopDuration else { return full }
    let start = CMTimeAdd(file.firstPresentationTime, CMTime(seconds: clampedStart, preferredTimescale: 1_000_000_000))
    let end = CMTimeAdd(file.firstPresentationTime, CMTime(seconds: clampedEnd, preferredTimescale: 1_000_000_000))
    let span = CMTimeSubtract(end, start)
    guard span.isNumeric, span.seconds + durationTolerance >= minimumLoopDuration else { return full }
    let isTrimmed = clampedStart > 1e-6 || clampedEnd < totalSeconds - 1e-6
    return EffectiveLoopWindow(start: start, end: end, length: span, isTrimmed: isTrimmed)
  }

  /// Updates the active loop window. Must be called on the feed queue (followed by `reposition`).
  func setLoopRange(_ loopRange: ClosedRange<Double>?) {
    window = Self.effectiveWindow(in: file, loopRange: loopRange)
    baseTimeOffset = .zero
    lastTrimmedVideoDTS = .invalid
    startedPassAtWindowStart = true
    emittedVisibleInPass = false
    needsResetDecoder = window.isTrimmed
  }

  /// Whether `file` is played round and round. One frame is a still picture: it is shown and
  /// held, not looped.
  static func loops(_ file: WebMFile) -> Bool {
    file.frameCount > 1 && file.duration.isNumeric && file.duration.seconds > 0
  }

  /// Where the pass of `file` that the clock time `time` falls in ends, which is where the clip
  /// starts over; nil for a file that does not loop. Reads only the file's fixed facts, so any
  /// thread may ask.
  static func endOfPass(
    containing time: CMTime, in file: WebMFile, loopRange: ClosedRange<Double>? = nil
  ) -> CMTime? {
    guard loops(file) else { return nil }
    let window = effectiveWindow(in: file, loopRange: loopRange)
    let pass = passIndex(of: time, first: window.start, length: window.length)
    return CMTimeAdd(window.start, CMTimeMultiplyByFloat64(window.length, multiplier: Double(pass + 1)))
  }

  var videoSamplesEnqueued: UInt64 { counters.withLock { $0 } }
  var audioBuffersEnqueued: UInt64 { audioFed.withLock { $0.buffers } }
  /// Where the sound was fed from after it was last moved to a time; invalid until a buffer is.
  var audioFedFromSinceMove: CMTime { audioFed.withLock { $0.firstSinceMove } }

  func release() {
    video = nil
    audio = nil
    heldAudio = nil
  }

  private func passOffset(_ pass: Int) -> CMTime {
    CMTimeAdd(baseTimeOffset, CMTimeMultiplyByFloat64(window.length, multiplier: Double(pass)))
  }

  /// Feeds while the renderer has room. False once the video has ended for good.
  func feedVideo(into sink: WebMSampleSink) -> Bool {
    while sink.hasRoom {
      guard let sample = nextVideo() else { return !videoDone }
      sink.accept(sample)
      counters.withLock { $0 += 1 }
    }
    return true
  }

  private func nextVideo() -> CMSampleBuffer? {
    guard let video, !videoDone else { return nil }
    if !window.isTrimmed {
      if let sample = video.copyNextSampleBuffer() {
        return applyPendingResetIfNeeded(sample)
      }
      if let error = video.error {
        videoDone = true
        onFailure?("the video could not be read: \(error.localizedDescription)")
        return nil
      }
      guard loops else {
        videoDone = true
        return nil
      }
      videoPass += 1
      video.timeOffset = passOffset(videoPass)
      _ = video.seek(to: .negativeInfinity)
      if let sample = video.copyNextSampleBuffer() {
        return applyPendingResetIfNeeded(sample)
      }
      videoDone = true
      onFailure?("the video could not be read again from its start")
      return nil
    }
    return nextTrimmedVideo(video)
  }

  private func applyPendingResetIfNeeded(_ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard needsResetDecoder else { return sample }
    needsResetDecoder = false
    return Self.retimeSample(
      sample,
      pts: CMSampleBufferGetPresentationTimeStamp(sample),
      dts: CMSampleBufferGetDecodeTimeStamp(sample),
      duration: CMSampleBufferGetDuration(sample),
      markDoNotDisplay: Self.isDoNotDisplay(sample),
      markResetDecoder: true)
  }

  /// Falls back cleanly to playing the full clip starting monotonically at `passClockStart` when
  /// a full pass over a trimmed `[window.start, window.end)` contains zero visible frames (for
  /// example a very low-fps clip whose frames straddle the window), avoiding a permanent black screen.
  private func fallbackToFullClip(from passClockStart: CMTime, video: WebMVideoReader) -> CMSampleBuffer? {
    window = EffectiveLoopWindow(
      start: first,
      end: CMTimeAdd(first, length),
      length: length,
      isTrimmed: false)
    let floor = lastTrimmedVideoDTS.isNumeric
      ? CMTimeMaximum(passClockStart, lastTrimmedVideoDTS)
      : passClockStart
    baseTimeOffset = first.isNumeric && floor.isNumeric
      ? CMTimeMaximum(.zero, CMTimeSubtract(floor, first))
      : .zero
    videoPass = 0
    emittedVisibleInPass = false
    startedPassAtWindowStart = true
    needsResetDecoder = true
    video.timeOffset = passOffset(0)
    _ = video.seek(to: .negativeInfinity)
    if let sample = video.copyNextSampleBuffer() {
      needsResetDecoder = false
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      let dts = CMSampleBufferGetDecodeTimeStamp(sample)
      let duration = CMSampleBufferGetDuration(sample)
      let clampedDTS = dts.isNumeric && lastTrimmedVideoDTS.isNumeric
        && CMTimeCompare(dts, lastTrimmedVideoDTS) < 0
        ? lastTrimmedVideoDTS : dts
      return Self.retimeSample(
        sample, pts: pts, dts: clampedDTS, duration: duration,
        markDoNotDisplay: Self.isDoNotDisplay(sample), markResetDecoder: true)
    }
    videoDone = true
    onFailure?("the video could not be read from its start")
    return nil
  }

  /// Reads the next video sample inside `[window.start, window.end)`:
  /// - Preroll frames between the rewound keyframe and `window.start` are marked `DoNotDisplay`
  ///   and clamped to the pass's start timestamp so the decoder builds valid reference frames
  ///   without displaying frames before `start`.
  /// - Hidden reference frames (such as VP9 alt-ref frames) with `pts >= window.end` keep
  ///   `DoNotDisplay` and stay clamped to the pass's end so trailing visible frames decode cleanly.
  /// - The first visible frame at or past `window.end` (or EOF) ends the pass and seamlessly
  ///   rewinds to the keyframe at or before `window.start` for the next pass.
  /// - Every sample's DTS is clamped monotonically against `passClockStart` and the prior DTS so
  ///   B-frame Matroska clips never emit non-monotonic decode timestamps.
  private func nextTrimmedVideo(_ video: WebMVideoReader) -> CMSampleBuffer? {
    var wrapsInCall = 0
    while true {
      let offset = passOffset(videoPass)
      let passClockStart = CMTimeAdd(window.start, offset)
      let passClockEnd = CMTimeAdd(window.end, offset)
      if let sample = video.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let filePTS = CMTimeSubtract(pts, offset)
        let hidden = Self.isDoNotDisplay(sample)

        if CMTimeCompare(filePTS, window.start) < 0 {
          let clampedDTS = lastTrimmedVideoDTS.isNumeric
            ? CMTimeMaximum(passClockStart, lastTrimmedVideoDTS) : passClockStart
          lastTrimmedVideoDTS = clampedDTS
          let reset = needsResetDecoder
          needsResetDecoder = false
          return Self.retimeSample(
            sample, pts: passClockStart, dts: clampedDTS, duration: .zero,
            markDoNotDisplay: true, markResetDecoder: reset)
        }

        if CMTimeCompare(filePTS, window.end) >= 0 {
          if hidden {
            let clampedDTS = lastTrimmedVideoDTS.isNumeric
              ? CMTimeMaximum(passClockEnd, lastTrimmedVideoDTS) : passClockEnd
            lastTrimmedVideoDTS = clampedDTS
            let reset = needsResetDecoder
            needsResetDecoder = false
            return Self.retimeSample(
              sample, pts: passClockEnd, dts: clampedDTS, duration: .zero,
              markDoNotDisplay: true, markResetDecoder: reset)
          }
          if !emittedVisibleInPass && startedPassAtWindowStart {
            return fallbackToFullClip(from: passClockStart, video: video)
          }
          guard loops, wrapsInCall == 0 else {
            videoDone = true
            return nil
          }
          wrapsInCall += 1
          videoPass += 1
          emittedVisibleInPass = false
          startedPassAtWindowStart = true
          needsResetDecoder = true
          video.timeOffset = passOffset(videoPass)
          _ = video.seek(to: window.start)
          continue
        }

        // Visible (or hidden) sample strictly within [window.start, window.end).
        if !hidden { emittedVisibleInPass = true }
        let reset = needsResetDecoder
        needsResetDecoder = false
        let sampleDuration = CMSampleBufferGetDuration(sample)
        let remaining = CMTimeSubtract(passClockEnd, pts)
        let needsDurationClamp = sampleDuration.isNumeric && remaining.isNumeric
          && CMTimeCompare(CMTimeAdd(pts, sampleDuration), passClockEnd) > 0
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dtsFloor = lastTrimmedVideoDTS.isNumeric
          ? CMTimeMaximum(passClockStart, lastTrimmedVideoDTS) : passClockStart
        let needsDTSClamp = dts.isNumeric && CMTimeCompare(dts, dtsFloor) < 0
        let clampedDTS = needsDTSClamp ? dtsFloor : dts
        if clampedDTS.isNumeric {
          lastTrimmedVideoDTS = lastTrimmedVideoDTS.isNumeric
            ? CMTimeMaximum(lastTrimmedVideoDTS, clampedDTS) : clampedDTS
        }
        if needsDurationClamp || needsDTSClamp || reset {
          let clampedDuration = needsDurationClamp ? CMTimeMaximum(.zero, remaining) : sampleDuration
          return Self.retimeSample(
            sample, pts: pts, dts: clampedDTS, duration: clampedDuration,
            markDoNotDisplay: hidden, markResetDecoder: reset)
        }
        return sample
      }

      if let error = video.error {
        videoDone = true
        onFailure?("the video could not be read: \(error.localizedDescription)")
        return nil
      }
      if !emittedVisibleInPass && startedPassAtWindowStart {
        return fallbackToFullClip(from: passClockStart, video: video)
      }
      guard loops, wrapsInCall == 0 else {
        videoDone = true
        return nil
      }
      wrapsInCall += 1
      videoPass += 1
      emittedVisibleInPass = false
      startedPassAtWindowStart = true
      needsResetDecoder = true
      video.timeOffset = passOffset(videoPass)
      _ = video.seek(to: window.start)
    }
  }

  private static func isDoNotDisplay(_ sample: CMSampleBuffer) -> Bool {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    return attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true
  }

  private static func retimeSample(
    _ sample: CMSampleBuffer, pts: CMTime, dts: CMTime, duration: CMTime,
    markDoNotDisplay: Bool, markResetDecoder: Bool
  ) -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
    var copy: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sample,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
    let result = (status == noErr ? copy : nil) ?? sample
    if markDoNotDisplay,
       let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0
    {
      let raw = CFArrayGetValueAtIndex(attachments, 0)
      let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if markResetDecoder {
      CMSetAttachment(
        result, key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }
    return result
  }

  func feedAudio(into sink: WebMSampleSink) -> Bool {
    while sink.hasRoom {
      guard let buffer = nextAudio() else { return !audioDone }
      sink.accept(buffer)
      let time = CMSampleBufferGetPresentationTimeStamp(buffer)
      audioFed.withLock {
        $0.buffers += 1
        if !$0.firstSinceMove.isValid { $0.firstSinceMove = time }
      }
    }
    return true
  }

  private func nextAudio() -> CMSampleBuffer? {
    guard let audio, !audioDone else { return nil }
    if let held = heldAudio {
      heldAudio = nil
      return held
    }
    if !window.isTrimmed {
      if let buffer = audio.copyNextSampleBuffer() { return buffer }
      if let error = audio.error {
        audioDone = true
        onAudioFailure?(error.localizedDescription)
        return nil
      }
      guard loops else {
        audioDone = true
        return nil
      }
      audioPass += 1
      audio.rewind(withTimeOffset: passOffset(audioPass), limit: length)
      if let buffer = audio.copyNextSampleBuffer() { return buffer }
      if let error = audio.error { onAudioFailure?(error.localizedDescription) }
      audioDone = true
      return nil
    }
    return nextTrimmedAudio(audio)
  }

  private func nextTrimmedAudio(_ audio: WebMAudioReader) -> CMSampleBuffer? {
    var wrapsInCall = 0
    while true {
      let offset = passOffset(audioPass)
      let passClockStart = CMTimeAdd(window.start, offset)
      let passClockEnd = CMTimeAdd(window.end, offset)
      if let buffer = audio.copyNextSampleBuffer() {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        if CMTimeCompare(start, passClockEnd) < 0 {
          if let sliced = Self.sliceAudioBuffer(buffer, from: passClockStart, to: passClockEnd) {
            return sliced
          }
          continue
        }
      } else if let error = audio.error {
        audioDone = true
        onAudioFailure?(error.localizedDescription)
        return nil
      }
      guard loops, wrapsInCall == 0 else {
        audioDone = true
        return nil
      }
      wrapsInCall += 1
      audioPass += 1
      let nextClockStart = CMTimeAdd(window.start, passOffset(audioPass))
      rewindAudioForPass(audioPass, advanceTo: nextClockStart)
      if let held = heldAudio {
        heldAudio = nil
        return held
      }
      if let error = audio.error { onAudioFailure?(error.localizedDescription) }
      audioDone = true
      return nil
    }
  }

  private func rewindAudioForPass(_ pass: Int, advanceTo targetClockTime: CMTime) {
    guard let audio else { return }
    let offset = passOffset(pass)
    heldAudio = nil
    if window.isTrimmed {
      let spanFromAudioStart = CMTimeSubtract(window.end, audio.startTime)
      guard spanFromAudioStart.isNumeric, spanFromAudioStart > .zero else { return }
      audio.rewind(withTimeOffset: offset, limit: spanFromAudioStart)
      let passClockStart = CMTimeAdd(window.start, offset)
      let passClockEnd = CMTimeAdd(window.end, offset)
      let effectiveTarget = CMTimeMaximum(passClockStart, targetClockTime)
      while let buffer = audio.copyNextSampleBuffer() {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        if CMTimeCompare(start, passClockEnd) >= 0 { break }
        if let sliced = Self.sliceAudioBuffer(buffer, from: effectiveTarget, to: passClockEnd) {
          heldAudio = sliced
          break
        }
      }
      return
    }
    audio.rewind(withTimeOffset: offset, limit: loops ? length : .invalid)
  }

  /// Trims leading linear-PCM frames before `startTime` (and trailing frames past `endTime`, if
  /// specified) using a zero-copy `CMBlockBuffer` reference so audio PTS never jumps backwards or
  /// overlaps the previous pass at loop seams.
  static func sliceAudioBuffer(
    _ buffer: CMSampleBuffer, from startTime: CMTime, to endTime: CMTime? = nil
  ) -> CMSampleBuffer? {
    let totalFrames = CMSampleBufferGetNumSamples(buffer)
    guard totalFrames > 0 else { return nil }
    let bufStart = CMSampleBufferGetPresentationTimeStamp(buffer)
    let bufDuration = CMSampleBufferGetDuration(buffer)
    guard bufStart.isNumeric else { return buffer }
    let bufEnd = bufDuration.isNumeric ? CMTimeAdd(bufStart, bufDuration) : bufStart
    if startTime.isNumeric, CMTimeCompare(bufEnd, startTime) <= 0 { return nil }
    if let endTime, endTime.isNumeric, CMTimeCompare(bufStart, endTime) >= 0 { return nil }

    guard let format = CMSampleBufferGetFormatDescription(buffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return buffer }
    let asbd = asbdPtr.pointee
    guard asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mFramesPerPacket == 1,
          asbd.mBytesPerFrame > 0,
          asbd.mSampleRate.isFinite, asbd.mSampleRate > 0
    else { return buffer }
    let rateScale = CMTimeScale(asbd.mSampleRate.rounded())
    guard rateScale > 0 else { return buffer }

    func framePTS(_ frameOffset: Int) -> CMTime {
      CMTimeAdd(bufStart, CMTime(value: Int64(frameOffset), timescale: rateScale))
    }

    var dropLeading = 0
    if startTime.isNumeric, CMTimeCompare(bufStart, startTime) < 0 {
      let delta = CMTimeSubtract(startTime, bufStart).seconds
      if delta.isFinite, delta > 0 {
        dropLeading = max(0, min(totalFrames, Int(floor(delta * asbd.mSampleRate))))
        while dropLeading < totalFrames && CMTimeCompare(framePTS(dropLeading), startTime) < 0 {
          dropLeading += 1
        }
      }
    }
    guard dropLeading < totalFrames else { return nil }

    var keepFrames = totalFrames - dropLeading
    if let endTime, endTime.isNumeric {
      let keptStart = framePTS(dropLeading)
      if CMTimeCompare(keptStart, endTime) >= 0 { return nil }
      if CMTimeCompare(framePTS(dropLeading + keepFrames), endTime) > 0 {
        let allowed = CMTimeSubtract(endTime, keptStart).seconds
        if allowed.isFinite, allowed > 0 {
          keepFrames = max(0, min(keepFrames, Int(floor(allowed * asbd.mSampleRate)) + 1))
          while keepFrames > 0 && CMTimeCompare(framePTS(dropLeading + keepFrames), endTime) > 0 {
            keepFrames -= 1
          }
        } else {
          return nil
        }
      }
    }
    guard keepFrames > 0 else { return nil }
    if dropLeading == 0 && keepFrames == totalFrames { return buffer }

    guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { return nil }
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    let byteOffset = dropLeading * bytesPerFrame
    let byteLength = keepFrames * bytesPerFrame
    guard byteOffset >= 0, byteLength > 0,
          byteOffset + byteLength <= CMBlockBufferGetDataLength(dataBuffer)
    else { return nil }

    var slicedBlock: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithBufferReference(
      allocator: kCFAllocatorDefault,
      referenceBuffer: dataBuffer,
      offsetToData: byteOffset,
      dataLength: byteLength,
      flags: 0,
      blockBufferOut: &slicedBlock)
    guard blockStatus == noErr, let slicedBlock else { return nil }

    var slicedSample: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: slicedBlock,
      formatDescription: format,
      sampleCount: keepFrames,
      presentationTimeStamp: framePTS(dropLeading),
      packetDescriptions: nil,
      sampleBufferOut: &slicedSample)
    guard sampleStatus == noErr, let slicedSample else { return nil }
    return slicedSample
  }

  /// Moves both readers to `time`: the video to the key frame at or before it within its pass, the
  /// sound to the buffer that covers it. Without `audio` the sound is left where it is.
  func reposition(at time: CMTime, audio moveAudio: Bool = true) {
    baseTimeOffset = .zero
    lastTrimmedVideoDTS = .invalid
    let pass = passIndex(of: time)
    if let video {
      videoPass = pass
      video.timeOffset = passOffset(pass)
      let targetInFile = CMTimeSubtract(time, passOffset(pass))
      let clampedTarget = window.isTrimmed && CMTimeCompare(targetInFile, window.start) < 0
        ? window.start : targetInFile
      _ = video.seek(to: clampedTarget)
      videoDone = false
      emittedVisibleInPass = false
      startedPassAtWindowStart = !window.isTrimmed || CMTimeCompare(clampedTarget, window.start) <= 0
      needsResetDecoder = window.isTrimmed
    }
    if moveAudio { repositionAudio(at: time) }
  }

  func repositionAudio(at time: CMTime) {
    guard let audio else { return }
    let pass = passIndex(of: time)
    audioPass = pass
    audioDone = false
    heldAudio = nil
    audioFed.withLock { $0.firstSinceMove = .invalid }
    if window.isTrimmed {
      let passClockStart = CMTimeAdd(window.start, passOffset(pass))
      let clamped = CMTimeCompare(time, passClockStart) < 0 ? passClockStart : time
      rewindAudioForPass(pass, advanceTo: clamped)
      return
    }
    audio.rewind(withTimeOffset: passOffset(pass), limit: loops ? length : .invalid)
    if pass == 0, CMTimeCompare(time, first) <= 0 { return }
    // Decode and drop what the clock has passed: the sound is rewound to its start and read forward.
    while let buffer = audio.copyNextSampleBuffer() {
      let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
      if end > time {
        heldAudio = buffer
        break
      }
    }
  }

  private func passIndex(of time: CMTime) -> Int {
    guard loops else { return 0 }
    return Self.passIndex(of: time, first: window.start, length: window.length)
  }

  private static func passIndex(of time: CMTime, first: CMTime, length: CMTime) -> Int {
    guard time.isNumeric, length.isNumeric, length.seconds > 0, time >= first else { return 0 }
    return max(0, Int(floor((time - first).seconds / length.seconds)))
  }
}
