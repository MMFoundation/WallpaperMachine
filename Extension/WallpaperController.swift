import AppKit

@MainActor
final class WallpaperController {
  static let shared = WallpaperController()
  private let surfaces = LockScreenSurfaceRegistry<WallpaperSurface>()
  private(set) var configuration: LockScreenConfiguration?
  private var observers: [NSObjectProtocol] = []
  /// Asked each time a surface decides whether to present, so a missed sleep or
  /// wake notification cannot leave it paused or rendering.
  let displayPower = DisplayPowerProbe.system
  /// Every signal that display power or the lock state may have changed only
  /// starts this: the answer comes from the system, now and over the next 2 s.
  private lazy var reevaluation = LockScreenReevaluationBurst(perform: { [weak self] in
    guard let self else { return }
    self.surfaces.values.forEach { self.refresh($0) }
  })
  private var started = false
  private var latestMedia: LockScreenMediaSnapshot?
  private var latestArtworkRGBA: Data?
  private var latestArtworkPNGDataURL = ""
  private var cachedArtworkRevision: UInt64 = 0
  private var lastPublishedDemand: LockScreenLiveDemand?
  private var pendingDemand: LockScreenLiveDemand?
  private enum LayerRead { case idle, reading, changed }
  private var layerRead = LayerRead.idle
  private var timelineTask: Task<Void, Never>?
  private var audioTask: Task<Void, Never>?
  private var pointerTask: Task<Void, Never>?
  private let pointerProbe = LockScreenPointerProbe.system
  private var pointerCadence = LockScreenPointerCadence()
  private let spectrumReader = LockScreenAudioSpectrumReader(exchange: WallpaperRuntime.exchange)
  private var lastForwardedAudioGeneration: UInt64 = 0
  private var webReceivedLiveAudio = false
  /// Static so the extension's listener can count a connection off the main queue.
  nonisolated static let idleExit = LockScreenIdleExit(
    grace: .seconds(30),
    isBusy: { !WallpaperController.shared.surfaces.values.isEmpty },
    exit: {
      WallpaperController.shared.clearLiveDemandOnExit()
      WallpaperRuntime.log("Exiting: no wallpaper host or surface remains.")
      Darwin.exit(0)
    })

  func start() {
    guard !started else { return }
    started = true
    WallpaperRuntime.removeLegacyExchange()
    reload()
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, cause) in [
      (NSWorkspace.screensDidSleepNotification, "display sleep"),
      (NSWorkspace.screensDidWakeNotification, "display wake"),
      (NSWorkspace.willSleepNotification, "system sleep"),
      (NSWorkspace.didWakeNotification, "system wake"),
      // Fast user switching moves the screens to another session without a lock.
      (NSWorkspace.sessionDidResignActiveNotification, "session switched away"),
      (NSWorkspace.sessionDidBecomeActiveNotification, "session active"),
    ] {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
        })
    }
    for (name, cause) in [
      ("com.apple.screenIsLocked", "screen locked"),
      ("com.apple.screenIsUnlocked", "screen unlocked"),
    ] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: .init(name), object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.presentationEnvironmentChanged(cause: cause) }
        })
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let controller = Unmanaged<WallpaperController>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { controller.reload() }
      }, LockScreenConfiguration.changedNotification as CFString, nil, .deliverImmediately)
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let controller = Unmanaged<WallpaperController>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { controller.reloadMedia() }
      }, LockScreenMediaSnapshot.changedNotification as CFString, nil, .deliverImmediately)
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let controller = Unmanaged<WallpaperController>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { controller.reloadSceneLayerStates() }
      }, LockScreenSceneLayerExchange.changedNotification as CFString, nil, .deliverImmediately)
  }

  func reload() {
    do {
      let next = try WallpaperRuntime.configuration()
      guard next != configuration else { return }
      configuration = next
      for surface in Array(surfaces.values) {
        refresh(surface)
      }
      WallpaperRuntime.log("Configuration loaded scenes=\(next.scenes.count)")
    } catch {
      // A removed/corrupt manifest must never keep rendering a previously private scene.
      configuration = nil
      surfaces.values.forEach { $0.clear() }
      reconcileLiveFeed()
      WallpaperRuntime.log("Configuration unavailable: \(error.localizedDescription)")
    }
  }

  func acknowledge(surface: WallpaperSurface, error: Error? = nil) {
    guard !surface.preview, let configuration,
      configuration.scenes(for: surface.content).contains(surface.scene),
      surfaces.values.contains(where: { $0 === surface })
    else { return }
    let scene = surface.scene
    let content = surface.content
    LockScreenReadiness.deliver(error: error, whenReady: { surface.whenReady($0) }) { [weak self, weak surface] readyError in
      guard let self, let surface, self.configuration == configuration,
        surface.scene == scene, surface.content == content,
        self.surfaces.values.contains(where: { $0 === surface })
      else { return }
      Self.record(
        LockScreenReadiness(
          revision: configuration.revision, displayID: scene.displayID,
          error: readyError?.localizedDescription, held: surface.heldNotice,
          content: content))
    }
  }

  /// A failure before any surface existed. Reported rather than left for the
  /// app to time out on, which it could only blame on macOS.
  private func acknowledge(scene: LockScreenScene, content: LockScreenContent, error: Error) {
    guard let configuration, configuration.scenes(for: content).contains(scene) else { return }
    Self.record(
      LockScreenReadiness(
        revision: configuration.revision, displayID: scene.displayID,
        error: error.localizedDescription, content: content))
  }

  private static func record(_ readiness: LockScreenReadiness) {
    var readiness = readiness
    readiness.processID = getpid()
    do {
      let data = try JSONEncoder().encode(readiness)
      try data.write(
        to: WallpaperRuntime.exchange.appendingPathComponent(
          LockScreenReadiness.fileName(displayID: readiness.displayID, content: readiness.content ?? .desktop)),
        options: .atomic)
    } catch {
      WallpaperRuntime.log("Readiness acknowledgement failed: \(error.localizedDescription)")
    }
  }

  private func refresh(_ surface: WallpaperSurface) {
    guard let configuration else { surface.clear(); return }
    let content = configuration.content(
      presentationMode: surface.presentation,
      sessionLocked: WallpaperPresentationAuthority.SessionState.current().locked,
      displayID: surface.displayID)
    guard let scene = configuration.scene(for: content, displayID: surface.displayID) else {
      surface.clear()
      return
    }
    let sharesRenderer = surface.scene.sharesRenderer(with: scene)
    if (!sharesRenderer || (!surface.hasContent && !surface.isLoading)), !surface.mayReplaceContent {
      surface.applyPolicy()
      return
    }
    let changedContent = surface.content != content
    surface.content = content
    if sharesRenderer, surface.isLoading {
      surface.update(scene: scene)
      if changedContent { acknowledge(surface: surface) }
    } else if surface.hasContent, sharesRenderer {
      surface.update(scene: scene)
      acknowledge(surface: surface)
    } else {
      let token = surface.pendingAcquires.begin()
      surface.replace(scene: scene, size: surface.size, scale: surface.scale) { [weak self, weak surface] error in
        guard let self, let surface, surface.pendingAcquires.complete(token, error: error) else { return }
        self.acknowledge(surface: surface, error: error)
        if let error { WallpaperRuntime.log("Replacement failed: \(error.localizedDescription)") }
      }
    }
  }

  func acquire(id value: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
    let started = ContinuousClock.now
    var acquiring: (LockScreenScene, LockScreenContent)?
    WallpaperRuntime.logRequestShape("acquire", request)
    do {
      guard let id = WallpaperRuntime.identifier(value), let request,
        let destination = WallpaperRuntime.field("destination", in: request),
        let size = WallpaperRuntime.field("size", in: destination) as? CGSize,
        let scale = WallpaperRuntime.field("scaleFactor", in: destination) as? CGFloat
      else {
        throw WallpaperRuntime.failure("Unsupported native wallpaper creation request.")
      }
      let displayID = WallpaperRuntime.field("directDisplayID", in: destination) as? UInt32
      let preview = WallpaperRuntime.field("isPreview", in: request) as? Bool ?? false
      let presentation = WallpaperRuntime.field("presentationMode", in: request)
        .map(WallpaperRuntime.enumCase) ?? surfaces[id]?.presentation ?? "active"
      reload()
      let content = configuration?.content(
        presentationMode: presentation,
        sessionLocked: WallpaperPresentationAuthority.SessionState.current().locked,
        displayID: displayID) ?? .desktop
      guard let scene = configuration?.scene(for: content, displayID: displayID) else {
        throw WallpaperRuntime.failure(
          "No applied wallpaper is available for this display. Enable Animate Lock Screen or Use wallpaper as screen saver in WallpaperMachine."
        )
      }
      if !preview { acquiring = (scene, content) }
      let acquisition = try surfaces.acquire(
        id: id, matches: { $0.displayID == displayID && $0.preview == preview }
      ) { generation in
        try WallpaperSurface(
          scene: scene, displayID: displayID, size: size, scale: scale, preview: preview,
          generation: generation)
      }
      let surface = acquisition.surface
      let generation = acquisition.generation
      surface.presentation = presentation
      surface.content = content
      if let activity = WallpaperRuntime.field("activityState", in: request) {
        surface.activity = WallpaperRuntime.enumCase(activity)
      }
      let ready: (Error?) -> Void = { [weak self, weak surface] error in
        guard let self, let surface,
          self.surfaces.isCurrent(id: id, surface: surface, generation: generation)
        else {
          reply(nil, CancellationError())
          return
        }
        do {
          if let error { throw error }
          let contextReply = try WallpaperRuntime.contextReply(surface.context.contextId)
          self.acknowledge(surface: surface)
          let elapsed = ContinuousClock.now - started
          reply(contextReply, nil)
          self.logFirstFrame(id: id, scene: surface.scene, preview: preview, elapsed: elapsed)
        } catch {
          if !(error is CancellationError) {
            WallpaperRuntime.log(
              "Acquire failed display=\(surface.scene.displayID) after "
                + "\(LockScreenFirstFrameTiming.seconds(ContinuousClock.now - started)) s: "
                + error.localizedDescription)
            self.acknowledge(surface: surface, error: error)
          }
          self.surfaces.retireAfterFailure(id, surface: surface, error: error)
          reply(nil, error)
        }
      }
      surface.pendingAcquires.append(ready)
      if !acquisition.isNew, surface.isLoading, surface.scene == scene,
        surface.size == size, surface.scale == scale
      {
        surface.applyPolicy()
        return
      }
      let token = surface.pendingAcquires.begin()
      let complete: (Error?) -> Void = { [weak surface] error in
        surface?.pendingAcquires.complete(token, error: error)
      }
      if acquisition.isNew {
        surface.start(completion: complete)
      } else if surface.hasContent, surface.scene == scene, surface.size == size, surface.scale == scale {
        surface.applyPolicy()
        surface.whenReady(complete)
      } else {
        // Keep the hosted context while replacing its child renderer.
        surface.replace(scene: scene, size: size, scale: scale, completion: complete)
      }
    } catch {
      reply(nil, error)
      WallpaperRuntime.log("Acquire failed: \(error.localizedDescription)")
      if let acquiring { acknowledge(scene: acquiring.0, content: acquiring.1, error: error) }
    }
  }

  /// The time from the request arriving to the reply carrying the surface. A first frame that
  /// takes most of WallpaperAgent's patience is called out on a line of its own.
  private func logFirstFrame(id: UUID, scene: LockScreenScene, preview: Bool, elapsed: Duration) {
    let seconds = LockScreenFirstFrameTiming.seconds(elapsed)
    let verdict = LockScreenFirstFrameTiming.classify(elapsed)
    WallpaperRuntime.log(
      "Acquired id=\(id) display=\(scene.displayID) preview=\(preview) "
        + "firstFrameAfter=\(seconds)s" + (verdict == .normal ? "" : " (\(verdict.rawValue))"))
    if verdict == .nearLimit {
      let patience = LockScreenFirstFrameTiming.seconds(LockScreenFirstFrameTiming.agentPatience)
      WallpaperRuntime.log(
        "First frame took \(seconds) s; WallpaperAgent gives up at about \(patience) s")
    }
  }

  /// A notice the wallpaper service forwards to its extensions. Waking is the only one that
  /// needs work: surfaces re-check whether they should be presenting. The others, such as
  /// `SignificantTimeChangeNotification`, are logged once so a new kind is noticed.
  func hostNotification(named name: String) {
    if name == "com.apple.wallpaper.hostDidWake" {
      presentationEnvironmentChanged(cause: "wallpaper service wake")
    } else if WallpaperRuntime.firstTime("host-notification-\(name)") {
      WallpaperRuntime.log("Host notification \(name) needs no action")
    }
  }

  /// Display power or the lock state may have changed. Nothing here trusts the signal to say
  /// which: each surface reads both from the system when it decides, now and again shortly
  /// after, because a display, a decoder or the session dictionary can trail the notification
  /// and some notifications never arrive.
  private func presentationEnvironmentChanged(cause: String) {
    WallpaperRuntime.log("Re-checking presentation (\(cause)) surfaces=\(surfaces.values.count)")
    reevaluation.trigger()
  }

  func update(id value: Any?, request: Any?) throws {
    WallpaperRuntime.logRequestShape("update", request)
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id], let request
    else { throw WallpaperRuntime.failure("Unknown wallpaper surface.") }
    if let mode = WallpaperRuntime.field("presentationMode", in: request) {
      surface.presentation = WallpaperRuntime.enumCase(mode)
    }
    if let activity = WallpaperRuntime.field("activityState", in: request) {
      surface.activity = WallpaperRuntime.enumCase(activity)
    }
    refresh(surface)
    WallpaperRuntime.log(
      "Updated id=\(id) mode=\(surface.presentation) activity=\(surface.activity)")
  }

  func invalidate(id value: Any?) {
    guard let id = WallpaperRuntime.identifier(value) else { return }
    remove(id)
  }

  func snapshot(id value: Any?, reply: @escaping (Any?, Error?) -> Void) {
    guard let id = WallpaperRuntime.identifier(value), let surface = surfaces[id] else {
      reply(nil, WallpaperRuntime.failure("Unknown wallpaper surface."))
      return
    }
    surface.snapshot(reply: reply)
  }

  /// Surfaces alive, for the line logged when a connection closes.
  var surfaceCount: Int { surfaces.values.count }

  private func remove(_ id: UUID) {
    surfaces.remove(id)
    reconcileLiveFeed()
    Self.idleExit.surfacesChanged()
  }

  // MARK: - Live Media & Audio Forwarding

  func reloadMedia() {
    guard loadMediaFromDisk() else {
      updateTimelineTimer()
      return
    }
    guard let snapshot = latestMedia else { return }
    let now = Date()
    for surface in Array(surfaces.values) where surface.isLiveMediaEligible {
      surface.deliverMedia(
        snapshot: snapshot,
        artworkRGBA: latestArtworkRGBA,
        artworkPNGDataURL: latestArtworkPNGDataURL,
        timelineAt: now,
        forceReplay: false)
    }
    updateTimelineTimer()
  }

  func replayMedia(to surface: WallpaperSurface) {
    guard surface.isLiveMediaEligible else { return }
    if latestMedia == nil {
      _ = loadMediaFromDisk()
    }
    guard let snapshot = latestMedia else { return }
    surface.deliverMedia(
      snapshot: snapshot,
      artworkRGBA: latestArtworkRGBA,
      artworkPNGDataURL: latestArtworkPNGDataURL,
      timelineAt: Date(),
      forceReplay: true)
    updateTimelineTimer()
  }

  func reconcileLiveFeed() {
    let activeSurfaces = Array(surfaces.values)
    let needsMedia = activeSurfaces.contains { $0.isLiveMediaEligible }
    let needsAudio = activeSurfaces.contains { $0.isLiveAudioEligible }
    let needsPointer = activeSurfaces.contains { $0.isLivePointerEligible }
    var requests = Set(activeSurfaces.compactMap(\.pendingLayerRequest))
    let limit = LockScreenSceneLayerExchange.maximumRequests
    if requests.count > limit {
      let continuing = requests.intersection((pendingDemand ?? lastPublishedDemand)?.layerRequests ?? [])
      requests = continuing.union(requests.subtracting(continuing).prefix(limit - continuing.count))
    }
    scheduleDemand(LockScreenLiveDemand(processID: getpid(), needsMedia: needsMedia, needsAudio: needsAudio,
      layerRequests: requests.isEmpty ? nil : requests))
    updateTimelineTimer()
    updateAudioTimer(active: needsAudio)
    updatePointerTimer(active: needsPointer)
  }

  private func reloadSceneLayerStates() {
    guard surfaces.values.contains(where: { $0.pendingLayerRequest != nil }) else { return }
    guard layerRead == .idle else { layerRead = .changed; return }
    layerRead = .reading
    let exchange = WallpaperRuntime.exchange
    Task {
      repeat {
        layerRead = .reading
        let states = await Task.detached(priority: .utility) {
          LockScreenSceneLayerExchange.read(from: exchange)
        }.value
        if !states.isEmpty {
          var consumed = false
          for surface in surfaces.values {
            if surface.applyLayerState(from: states) { consumed = true }
          }
          if consumed { reconcileLiveFeed() }
        }
      } while layerRead == .changed && surfaces.values.contains(where: { $0.pendingLayerRequest != nil })
      layerRead = .idle
    }
  }

  private func clearLiveDemandOnExit() {
    timelineTask?.cancel()
    timelineTask = nil
    audioTask?.cancel()
    audioTask = nil
    pointerTask?.cancel()
    pointerTask = nil
    pointerCadence.reset()
    spectrumReader.close()
    pendingDemand = nil
    publishDemandIfChanged(LockScreenLiveDemand(processID: getpid(), needsMedia: false, needsAudio: false))
  }

  @discardableResult
  private func loadMediaFromDisk() -> Bool {
    guard let snapshot = LockScreenMediaSnapshot.read(from: WallpaperRuntime.exchange) else {
      latestMedia = nil
      latestArtworkRGBA = nil
      latestArtworkPNGDataURL = ""
      cachedArtworkRevision = 0
      return false
    }
    if let thumb = snapshot.thumbnail {
      if thumb.artworkRevision != cachedArtworkRevision {
        cachedArtworkRevision = thumb.artworkRevision
        latestArtworkRGBA = LockScreenMediaSnapshot.readArtworkRGBA(
          from: WallpaperRuntime.exchange, thumbnail: thumb)
        latestArtworkPNGDataURL = LockScreenMediaSnapshot.readArtworkPNGDataURL(
          from: WallpaperRuntime.exchange, thumbnail: thumb)
      }
    } else if cachedArtworkRevision != 0 || latestArtworkRGBA != nil || !latestArtworkPNGDataURL.isEmpty {
      cachedArtworkRevision = 0
      latestArtworkRGBA = nil
      latestArtworkPNGDataURL = ""
    }
    latestMedia = snapshot
    return true
  }

  private func scheduleDemand(_ demand: LockScreenLiveDemand) {
    guard demand != (pendingDemand ?? lastPublishedDemand) else { return }
    let scheduled = pendingDemand != nil
    pendingDemand = demand
    guard !scheduled else { return }
    DispatchQueue.main.async {
      guard let demand = self.pendingDemand else { return }
      self.pendingDemand = nil
      self.publishDemandIfChanged(demand)
    }
  }

  private func publishDemandIfChanged(_ demand: LockScreenLiveDemand) {
    guard demand != lastPublishedDemand else { return }
    let url = WallpaperRuntime.exchange.appendingPathComponent(LockScreenLiveDemand.fileName)
    do {
      if demand.needsMedia || demand.needsAudio || demand.layerRequests?.isEmpty == false {
        let data = try JSONEncoder().encode(demand)
        try data.write(to: url, options: .atomic)
      } else if unlink(url.path) != 0, errno != ENOENT {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      WallpaperRuntime.log("Live demand write failed: \(error.localizedDescription)")
      return
    }
    lastPublishedDemand = demand
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(LockScreenLiveDemand.changedNotification as CFString),
      nil, nil, true)
  }

  private func updateTimelineTimer() {
    let shouldTick = latestMedia?.playbackState == 0
      && latestMedia?.timeline != nil
      && surfaces.values.contains { $0.isLiveMediaEligible }
    guard shouldTick != (timelineTask != nil) else { return }
    timelineTask?.cancel()
    timelineTask = nil
    guard shouldTick else { return }
    timelineTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let snapshot = self.latestMedia, snapshot.playbackState == 0,
          let timeline = snapshot.interpolatedTimeline(at: Date())
        else {
          self.updateTimelineTimer()
          return
        }
        let eligible = Array(self.surfaces.values).filter { $0.isLiveMediaEligible }
        guard !eligible.isEmpty else {
          self.updateTimelineTimer()
          return
        }
        for surface in eligible {
          surface.deliverTimelineTick(position: timeline.position, duration: timeline.duration)
        }
      }
    }
  }

  private func updateAudioTimer(active: Bool) {
    guard active != (audioTask != nil) else { return }
    audioTask?.cancel()
    audioTask = nil
    if !active {
      spectrumReader.close()
      lastForwardedAudioGeneration = 0
      if webReceivedLiveAudio {
        webReceivedLiveAudio = false
        for surface in Array(surfaces.values) where surface.isWebSurface {
          surface.deliverWebAudio(bins: nil, liveActive: false)
        }
      }
      return
    }
    lastForwardedAudioGeneration = 0
    audioTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        self.pumpAudioOnce()
        do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
      }
    }
  }

  private func pumpAudioOnce() {
    let eligible = Array(surfaces.values).filter { $0.isLiveAudioEligible }
    guard !eligible.isEmpty else {
      updateAudioTimer(active: false)
      return
    }
    let hasScene = eligible.contains { $0.isSceneSurface }
    let webSurfaces = eligible.filter { $0.isWebSurface }
    if let frame = spectrumReader.read() {
      guard frame.generation != lastForwardedAudioGeneration else { return }
      lastForwardedAudioGeneration = frame.generation
      if hasScene {
        frame.bands.withUnsafeBufferPointer { buffer in
          if let pointer = buffer.baseAddress {
            _ = owe_audio_submit_spectrum_full(pointer, UInt(buffer.count), frame.stereo)
          }
        }
      }
      if !webSurfaces.isEmpty {
        let bins = frame.clampedWebBins128()
        for surface in webSurfaces {
          surface.deliverWebAudio(bins: bins, liveActive: true)
        }
        webReceivedLiveAudio = true
      }
    } else if webReceivedLiveAudio {
      webReceivedLiveAudio = false
      let silence = [Double](repeating: 0, count: LockScreenAudioSpectrumChannel.webBinCount)
      for surface in webSurfaces {
        surface.deliverWebAudio(bins: silence, liveActive: false)
      }
    }
  }

  // MARK: - Live Lock-Screen Cursor Tracking

  func refreshPointerIfNeeded() {
    guard pointerTask != nil else { return }
    _ = pumpPointerOnce()
  }

  private func updatePointerTimer(active: Bool) {
    guard active != (pointerTask != nil) else {
      if active, surfaces.values.contains(where: \.needsInitialPointerSample) {
        _ = pumpPointerOnce()
      }
      return
    }
    pointerTask?.cancel()
    pointerTask = nil
    pointerCadence.reset()
    guard active else { return }
    pointerTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        guard let delay = self.pumpPointerOnce() else { return }
        do { try await Task.sleep(for: delay) } catch { return }
      }
    }
  }

  private func pumpPointerOnce() -> Duration? {
    let eligible = Array(surfaces.values).filter { $0.isLivePointerEligible }
    guard !eligible.isEmpty else {
      updatePointerTimer(active: false)
      return nil
    }
    let now = ContinuousClock.now
    let maxFPS = eligible.map(\.scene.fps).max() ?? LockScreenPointerCadence.maxActiveFPS
    guard let cursor = pointerProbe.cursorLocation() else {
      return LockScreenPointerCadence.stationaryInterval
    }
    let moved = pointerCadence.recordSample(cursor, at: now)
    if moved || eligible.contains(where: \.needsInitialPointerSample) {
      var boundsByDisplay: [UInt32: CGRect?] = [:]
      for surface in eligible where surface.canDeliverPointerNow {
        let displayID = surface.pointerDisplayID
        let bounds: CGRect?
        if let cached = boundsByDisplay[displayID] {
          bounds = cached
        } else {
          let fetched = displayID != 0 ? pointerProbe.displayBounds(displayID) : nil
          boundsByDisplay[displayID] = fetched
          bounds = fetched
        }
        surface.deliverPointer(cursor: cursor, in: bounds)
      }
    }
    return pointerCadence.nextInterval(maxFPS: maxFPS, at: now)
  }
}
