import AppKit
import Darwin
import Foundation

/// Bridges live Now Playing media state and system-audio spectrum from the main app
/// into `LockScreenExchange/` for the sandboxed lock-screen / screen-saver extension.
///
/// Power & zero-disk-thrashing invariants:
/// - Both media consumption and CoreAudio capture stay off until the extension publishes
///   active demand from a live process AND lock screen / screen saver is enabled AND
///   displays are awake AND playback is not paused.
/// - Display sleep, system sleep, user pause, disabling lock screen / screen saver,
///   extension exit, or app shutdown immediately stop both feeds and clean up exchange files.
/// - `media-state.json` is written only on track, playback, artwork or seek changes (never
///   once per second); the extension interpolates playback progress locally at 1 Hz.
/// - `audio-spectrum.shm` is a single 4096-byte `mmap` seqlock page updated in RAM at 30 Hz
///   without `msync`, only while the extension has an unpaused audio-reading surface.
@MainActor
final class LockScreenLiveFeedCoordinator {
  private final class ListenerKey {}

  private struct ArtworkSignature: Equatable {
    var rgba: [UInt8]
    var pngDataURL: String
    var width: Int
    var height: Int
  }

  /// Position drift beyond which a playing timeline tick counts as a real seek and
  /// triggers an exchange write rather than being left to local 1 Hz interpolation.
  static let seekWriteThresholdSeconds: Double = 1.5
  static let pausedTimelineWriteThresholdSeconds: Double = 0.25

  private let exchange: URL
  private let session: DesktopMediaSession
  private let canDeliver: @MainActor () -> Bool
  private let displaysAsleep: @MainActor () -> Bool
  private let setAudioDemand: @MainActor (Bool) async throws -> Void
  private let readAudioSpectrum: @MainActor () throws -> BridgeAudioSpectrumFull?
  private let isProcessAlive: @MainActor (Int32) -> Bool
  private let watchProcessExit: @MainActor (Int32, @escaping @MainActor () -> Void) -> () -> Void
  private let observeDemandNotification: @MainActor (@escaping @MainActor () -> Void) -> () -> Void
  private let postMediaChanged: @MainActor () -> Void
  private let observeWorkspaceSleep: @MainActor (@escaping @MainActor (Bool) -> Void) -> () -> Void
  private let now: @MainActor () -> Date
  private let nowNanos: @MainActor () -> UInt64
  private let audioInterval: Duration

  private let listenerToken = ListenerKey()
  private var listenerKey: ObjectIdentifier { ObjectIdentifier(listenerToken) }

  private var started = false
  private var stopped = false
  private var systemSleeping = false
  private var currentDemand: LockScreenLiveDemand?
  private var watchedPID: Int32?
  private var cancelProcessWatch: (() -> Void)?
  private var cancelDemandObserver: (() -> Void)?
  private var cancelSleepObserver: (() -> Void)?

  // Media forwarding state
  private(set) var mediaActive = false
  private var suppressPublishDuringAttach = false
  /// Randomized high bits prevent generation/artwork-revision collisions across app restarts
  /// while still incrementing strictly by +1 within a session.
  private var mediaGeneration: UInt64 = UInt64.random(in: 1...0xFFFF_FFFF) << 16
  private var properties = LockScreenMediaSnapshot.Properties()
  private var playbackState: Int = SystemMediaPlaybackState.stopped.rawValue
  private var timeline: LockScreenMediaSnapshot.Timeline?
  private var thumbnail: LockScreenMediaSnapshot.Thumbnail?
  private var pendingArtworkRGBA: Data?
  private var pendingArtworkPNG: Data?
  private var lastArtworkSignature: ArtworkSignature?
  private var artworkRevision: UInt64 = UInt64.random(in: 1...0xFFFF_FFFF) << 16

  // Audio forwarding state
  private(set) var audioActive = false
  private let spectrumWriter: LockScreenAudioSpectrumWriter
  private var audioTask: Task<Void, Never>?
  private var lastWrittenAudioGeneration: UInt64 = 0
  private var bridgeAudioDemandChain: Task<Void, Never>?
  private var reportedBridgeAudioDemand = false

  convenience init(
    bridge: WallpaperBridge,
    session: DesktopMediaSession,
    canDeliver: @escaping @MainActor () -> Bool,
    exchange: URL = LockScreenConfiguration.exchangeDirectory
  ) {
    self.init(
      exchange: exchange,
      session: session,
      canDeliver: canDeliver,
      displaysAsleep: { DisplayPowerProbe.system.displaysAsleep(for: nil) },
      setAudioDemand: { active in
        try await bridge.setLockScreenAudioDemand(active: active)
      },
      readAudioSpectrum: {
        try bridge.lockScreenAudioSpectrum()
      }
    )
  }

  init(
    exchange: URL,
    session: DesktopMediaSession,
    canDeliver: @escaping @MainActor () -> Bool,
    displaysAsleep: @escaping @MainActor () -> Bool = { false },
    setAudioDemand: @escaping @MainActor (Bool) async throws -> Void,
    readAudioSpectrum: @escaping @MainActor () throws -> BridgeAudioSpectrumFull?,
    isProcessAlive: @escaping @MainActor (Int32) -> Bool = LockScreenLiveFeedCoordinator.defaultIsProcessAlive,
    watchProcessExit: @escaping @MainActor (Int32, @escaping @MainActor () -> Void) -> () -> Void =
      LockScreenWallpaperService.watchProcessExit,
    observeDemandNotification: @escaping @MainActor (@escaping @MainActor () -> Void) -> () -> Void =
      LockScreenLiveFeedCoordinator.defaultObserveDemandNotification,
    postMediaChanged: @escaping @MainActor () -> Void = LockScreenLiveFeedCoordinator.defaultPostMediaChanged,
    observeWorkspaceSleep: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> () -> Void =
      LockScreenLiveFeedCoordinator.defaultObserveWorkspaceSleep,
    now: @escaping @MainActor () -> Date = { Date() },
    nowNanos: @escaping @MainActor () -> UInt64 = { LockScreenAudioSpectrumChannel.nowNanoseconds() },
    audioInterval: Duration = .milliseconds(33)
  ) {
    self.exchange = exchange
    self.session = session
    self.canDeliver = canDeliver
    self.displaysAsleep = displaysAsleep
    self.setAudioDemand = setAudioDemand
    self.readAudioSpectrum = readAudioSpectrum
    self.isProcessAlive = isProcessAlive
    self.watchProcessExit = watchProcessExit
    self.observeDemandNotification = observeDemandNotification
    self.postMediaChanged = postMediaChanged
    self.observeWorkspaceSleep = observeWorkspaceSleep
    self.now = now
    self.nowNanos = nowNanos
    self.audioInterval = audioInterval
    self.spectrumWriter = LockScreenAudioSpectrumWriter(exchange: exchange)
  }

  func start() {
    guard !started, !stopped else { return }
    started = true
    session.relay.addListener(listenerKey) { [weak self] event in
      self?.handleMediaEvent(event)
    }
    cancelDemandObserver = observeDemandNotification { [weak self] in
      self?.refreshDemandFromDisk()
    }
    cancelSleepObserver = observeWorkspaceSleep { [weak self] sleeping in
      guard let self, !self.stopped else { return }
      self.systemSleeping = sleeping
      self.reconcile()
    }
    refreshDemandFromDisk()
  }

  func refreshDemandFromDisk() {
    guard !stopped else { return }
    let url = exchange.appendingPathComponent(LockScreenLiveDemand.fileName)
    guard let data = try? Data(contentsOf: url),
      let demand = try? JSONDecoder().decode(LockScreenLiveDemand.self, from: data),
      demand.processID > 0,
      isProcessAlive(demand.processID)
    else {
      clearDemand()
      reconcile()
      return
    }
    let previousPID = currentDemand?.processID
    currentDemand = demand
    installProcessWatchIfNeeded(for: demand.processID)
    reconcile()
    // If a new extension process came up while media was already active, re-notify it so
    // it reads the existing snapshot immediately.
    if mediaActive, previousPID != demand.processID {
      postMediaChanged()
    }
  }

  func reconcile() {
    let asleep = systemSleeping || displaysAsleep()
    let allowed = started && !stopped && canDeliver() && !asleep
    let wantMedia = allowed && (currentDemand?.needsMedia ?? false)
    let wantAudio = allowed && (currentDemand?.needsAudio ?? false)
    updateMediaActive(wantMedia)
    updateAudioActive(wantAudio)
  }

  /// Drives a single audio pump tick synchronously; exposed for deterministic unit tests.
  func pumpAudioOnce() {
    guard audioActive, !stopped else { return }
    do {
      guard let spectrum = try readAudioSpectrum(),
        spectrum.generation > 0,
        spectrum.bands.count == LockScreenAudioSpectrumChannel.bandCount,
        spectrum.generation != lastWrittenAudioGeneration
      else { return }
      if spectrumWriter.write(
        generation: spectrum.generation,
        stereo: spectrum.stereo,
        bands: spectrum.bands,
        nowNanos: nowNanos()
      ) {
        lastWrittenAudioGeneration = spectrum.generation
      }
    } catch {
      AppLog.warn("lock screen audio spectrum read failed: \(error.localizedDescription)")
    }
  }

  func shutdown() {
    guard !stopped else { return }
    stopped = true
    cancelDemandObserver?()
    cancelDemandObserver = nil
    cancelSleepObserver?()
    cancelSleepObserver = nil
    clearDemand()
    updateMediaActive(false)
    updateAudioActive(false)
    session.relay.removeListener(listenerKey)
  }

  private func clearDemand() {
    currentDemand = nil
    watchedPID = nil
    cancelProcessWatch?()
    cancelProcessWatch = nil
  }

  private func installProcessWatchIfNeeded(for pid: Int32) {
    guard watchedPID != pid else { return }
    cancelProcessWatch?()
    watchedPID = pid
    cancelProcessWatch = watchProcessExit(pid) { [weak self] in
      guard let self, !self.stopped, self.watchedPID == pid else { return }
      self.clearDemand()
      self.reconcile()
    }
  }

  // MARK: - Media Forwarding

  private func updateMediaActive(_ active: Bool) {
    guard mediaActive != active else { return }
    mediaActive = active
    if active {
      resetMediaCache()
      suppressPublishDuringAttach = true
      session.relay.setConsuming(true, for: listenerKey)
      // Ingest everything already held in the relay (covers both a dormant provider that
      // just replayed and an already-running desktop provider whose values were unchanged).
      for event in session.relay.currentEvents(userEnabled: true) {
        _ = ingestMediaEvent(event, forceTimeline: true)
      }
      suppressPublishDuringAttach = false
      writeMediaSnapshot(writeArtworkFiles: thumbnail != nil)
    } else {
      session.relay.setConsuming(false, for: listenerKey)
      resetMediaCache()
      LockScreenMediaSnapshot.removeFiles(in: exchange)
      postMediaChanged()
    }
  }

  private func resetMediaCache() {
    properties = LockScreenMediaSnapshot.Properties()
    playbackState = SystemMediaPlaybackState.stopped.rawValue
    timeline = nil
    thumbnail = nil
    pendingArtworkRGBA = nil
    pendingArtworkPNG = nil
    lastArtworkSignature = nil
  }

  private func handleMediaEvent(_ event: WebWallpaperMediaRelay.Event) {
    guard mediaActive, !stopped, !suppressPublishDuringAttach else { return }
    let change = ingestMediaEvent(event, forceTimeline: false)
    guard change.needsStateWrite else { return }
    writeMediaSnapshot(writeArtworkFiles: change.artworkChanged)
  }

  private struct MediaChange {
    var needsStateWrite = false
    var artworkChanged = false
  }

  private func ingestMediaEvent(
    _ event: WebWallpaperMediaRelay.Event, forceTimeline: Bool
  ) -> MediaChange {
    var change = MediaChange()
    switch event {
    case .status:
      return change
    case let .properties(next):
      let mapped = LockScreenMediaSnapshot.Properties(
        title: next.title,
        artist: next.artist,
        subTitle: next.subTitle,
        albumTitle: next.albumTitle,
        albumArtist: next.albumArtist,
        genres: next.genres,
        contentType: next.contentType
      )
      if mapped != properties {
        properties = mapped
        change.needsStateWrite = true
      }
    case let .playback(state):
      let nextRaw = state.rawValue
      if nextRaw != playbackState {
        // Re-anchor any active timeline to the current interpolated position at the
        // exact moment playback transitions (e.g., playing -> paused freezes here).
        let currentTime = now()
        if let existing = timeline {
          let snapshot = LockScreenMediaSnapshot(
            generation: mediaGeneration, properties: properties,
            playbackState: playbackState, timeline: existing, thumbnail: thumbnail)
          if let current = snapshot.interpolatedTimeline(at: currentTime) {
            timeline = LockScreenMediaSnapshot.Timeline(
              position: current.position, duration: current.duration,
              anchorWallTime: currentTime.timeIntervalSince1970)
          }
        }
        playbackState = nextRaw
        change.needsStateWrite = true
      }
    case let .thumbnail(next):
      let signature = ArtworkSignature(
        rgba: next.rgba, pngDataURL: next.pngBase64DataURL, width: next.width, height: next.height)
      let artworkChanged = signature != lastArtworkSignature
      if artworkChanged {
        lastArtworkSignature = signature
        artworkRevision &+= 1
        if !next.isEmpty,
          next.width > 0, next.height > 0,
          next.width <= LockScreenMediaSnapshot.maxArtworkDimension,
          next.height <= LockScreenMediaSnapshot.maxArtworkDimension,
          next.rgba.count == next.width * next.height * 4
        {
          pendingArtworkRGBA = Data(next.rgba)
        } else {
          pendingArtworkRGBA = nil
        }
        pendingArtworkPNG = next.isEmpty
          ? nil : LockScreenMediaSnapshot.decodePNGDataURL(next.pngBase64DataURL)
        change.artworkChanged = true
      }
      let hasArtwork = pendingArtworkRGBA != nil || pendingArtworkPNG != nil
      let mapped = LockScreenMediaSnapshot.Thumbnail(
        primaryColor: next.primaryColor,
        secondaryColor: next.secondaryColor,
        tertiaryColor: next.tertiaryColor,
        textColor: next.textColor,
        highContrastColor: next.highContrastColor,
        width: pendingArtworkRGBA != nil ? next.width : 0,
        height: pendingArtworkRGBA != nil ? next.height : 0,
        artworkRevision: artworkRevision,
        hasArtwork: hasArtwork
      )
      if mapped != thumbnail || artworkChanged {
        thumbnail = mapped
        change.needsStateWrite = true
      }
    case let .timeline(next):
      guard next.position.isFinite, next.duration.isFinite else { return change }
      let currentTime = now()
      let position = max(0, next.position)
      let duration = max(0, next.duration)
      if !forceTimeline, let existing = timeline {
        let sameDuration = abs(existing.duration - duration) < 0.05
        if sameDuration {
          let snapshot = LockScreenMediaSnapshot(
            generation: mediaGeneration, properties: properties,
            playbackState: playbackState, timeline: existing, thumbnail: thumbnail)
          if let predicted = snapshot.interpolatedTimeline(at: currentTime) {
            let threshold = playbackState == SystemMediaPlaybackState.playing.rawValue
              ? Self.seekWriteThresholdSeconds : Self.pausedTimelineWriteThresholdSeconds
            if abs(position - predicted.position) <= threshold {
              // Ordinary 1 Hz tick matches local interpolation: zero disk writes.
              return change
            }
          }
        }
      }
      timeline = LockScreenMediaSnapshot.Timeline(
        position: position, duration: duration, anchorWallTime: currentTime.timeIntervalSince1970)
      change.needsStateWrite = true
    }
    return change
  }

  private func writeMediaSnapshot(writeArtworkFiles: Bool) {
    do {
      try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
      if writeArtworkFiles {
        let rgbaURL = exchange.appendingPathComponent(LockScreenMediaSnapshot.artworkRGBAFileName)
        if let rgba = pendingArtworkRGBA {
          try rgba.write(to: rgbaURL, options: .atomic)
        } else {
          try? FileManager.default.removeItem(at: rgbaURL)
        }
        let pngURL = exchange.appendingPathComponent(LockScreenMediaSnapshot.artworkPNGFileName)
        if let png = pendingArtworkPNG {
          try png.write(to: pngURL, options: .atomic)
        } else {
          try? FileManager.default.removeItem(at: pngURL)
        }
      }
      mediaGeneration &+= 1
      let snapshot = LockScreenMediaSnapshot(
        generation: mediaGeneration,
        properties: properties,
        playbackState: playbackState,
        timeline: timeline,
        thumbnail: thumbnail
      )
      let data = try JSONEncoder().encode(snapshot)
      let stateURL = exchange.appendingPathComponent(LockScreenMediaSnapshot.stateFileName)
      try data.write(to: stateURL, options: .atomic)
      postMediaChanged()
    } catch {
      AppLog.warn("lock screen media snapshot write failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Audio Forwarding

  private func updateAudioActive(_ active: Bool) {
    guard audioActive != active else { return }
    audioActive = active
    if active {
      lastWrittenAudioGeneration = 0
      _ = spectrumWriter.openIfNeeded()
      pushBridgeAudioDemand(true)
      audioTask?.cancel()
      audioTask = Task { @MainActor [weak self] in
        while let self, !Task.isCancelled, self.audioActive, !self.stopped {
          self.pumpAudioOnce()
          do { try await Task.sleep(for: self.audioInterval) } catch { return }
        }
      }
    } else {
      audioTask?.cancel()
      audioTask = nil
      lastWrittenAudioGeneration = 0
      spectrumWriter.deactivate(removeFile: true)
      pushBridgeAudioDemand(false)
    }
  }

  private func pushBridgeAudioDemand(_ active: Bool) {
    guard reportedBridgeAudioDemand != active else { return }
    reportedBridgeAudioDemand = active
    let previous = bridgeAudioDemandChain
    bridgeAudioDemandChain = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      do {
        try await self.setAudioDemand(active)
      } catch {
        AppLog.warn("lock screen audio demand update (\(active)) failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Production Defaults

  private nonisolated static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  private final class NotificationBox {
    let fire: @MainActor () -> Void
    init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
  }

  private static func defaultObserveDemandNotification(
    _ handler: @escaping @MainActor () -> Void
  ) -> () -> Void {
    let box = Unmanaged.passRetained(NotificationBox(handler))
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = LockScreenLiveDemand.changedNotification as CFString
    CFNotificationCenterAddObserver(
      center, box.toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let target = Unmanaged<NotificationBox>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async {
          MainActor.assumeIsolated { target.fire() }
        }
      },
      name, nil, .deliverImmediately
    )
    var removed = false
    return {
      guard !removed else { return }
      removed = true
      CFNotificationCenterRemoveObserver(
        center, box.toOpaque(), CFNotificationName(name), nil)
      box.release()
    }
  }

  private static func defaultPostMediaChanged() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(LockScreenMediaSnapshot.changedNotification as CFString),
      nil, nil, true
    )
  }

  private static func defaultObserveWorkspaceSleep(
    _ handler: @escaping @MainActor (Bool) -> Void
  ) -> () -> Void {
    let workspace = NSWorkspace.shared.notificationCenter
    var tokens: [NSObjectProtocol] = []
    for (name, sleeping) in [
      (NSWorkspace.screensDidSleepNotification, true),
      (NSWorkspace.willSleepNotification, true),
      (NSWorkspace.screensDidWakeNotification, false),
      (NSWorkspace.didWakeNotification, false),
    ] {
      tokens.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { handler(sleeping) }
        }
      )
    }
    return {
      for token in tokens { workspace.removeObserver(token) }
      tokens.removeAll()
    }
  }
}
