import AppKit
import CoreVideo
import IOSurface
import Metal

/// One WallpaperID is one compositor surface: never share a CAContext across Spaces.
@MainActor
final class WallpaperSurface: LockScreenSurfaceLifecycle {
  let context: CAContext
  let root: CALayer
  private(set) var scene: LockScreenScene
  let displayID: UInt32?
  private(set) var size: CGSize
  private(set) var scale: CGFloat
  let preview: Bool
  var presentation = "active"
  var content: LockScreenContent = .desktop
  var activity = "active"
  private var layer: CAMetalLayer?
  private var renderer: OpaquePointer?
  private var web: ScreenSaverWebSurface?
  /// The player of a plain video wallpaper (an AVFoundation layer, or the WebM player for the files
  /// AVFoundation cannot open), in place of `renderer`.
  private var video: LockScreenVideoPlaying?
  private var nativeStart: Task<Void, Never>?
  private var contentError: Error?
  /// Set once, when the engine reports it cannot draw the scene (Native Metal is the only renderer), or when
  /// the extension's players cannot play a video. The surface then keeps what it shows
  /// and says why; it is not a `contentError`, because the surface is alive and showing a picture, and
  /// the same wallpaper can reuse it.
  private var heldFailure: LockScreenHeldFailure?
  /// The localized note about `heldFailure` the readiness file carries to the app.
  private(set) var heldNotice: String?
  private var frameObserver: NSObjectProtocol?
  private var firstFrameReply: ((Error?) -> Void)?
  private var readyWaiters: [(Error?) -> Void] = []
  private var deadline: Task<Void, Never>?
  private var snapshotWaiters: [(Any?, Error?) -> Void] = []
  private var snapshotDeadline: Task<Void, Never>?
  private var latestSnapshot: IOSurface?
  private var stopped = false
  var isReusable: Bool { !stopped && contentError == nil }
  var hasContent: Bool {
    renderer != nil || video != nil || heldFailure != nil || (web != nil && contentError == nil)
  }
  var isLoading: Bool { firstFrameReply != nil }
  let pendingAcquires = LockScreenAcquireReplies()
  private var rendererPaused = false
  private(set) var sceneRequiresAudio = false
  private(set) var sceneAcceptsPointerInput = true
  private var pointerDelivery = LockScreenPointerDelivery()
  private var appliedMediaIntegrationEnabled = false
  private var appliedAudioResponseEnabled = false
  private var lastDeliveredMediaGeneration: UInt64 = 0
  private var lastDeliveredArtworkRevision: UInt64 = 0
  private var isLivePresentationContent: Bool {
    content == .lockScreen || content == .screenSaver
  }
  private var desiredWebMediaEnabled: Bool {
    !preview && !stopped && !rendererPaused && isLivePresentationContent
      && scene.effectiveMediaIntegrationEnabled
  }
  /// Whether this surface is presenting an unpaused lock screen or screen saver that
  /// should receive live Now Playing media updates. Never true for previews, unlocked
  /// desktop settle surfaces, plain videos, or paused surfaces.
  var isLiveMediaEligible: Bool {
    guard !preview, !stopped, !rendererPaused, firstFrameReply == nil,
      isLivePresentationContent, scene.effectiveMediaIntegrationEnabled
    else { return false }
    if renderer != nil { return true }
    if let web, contentError == nil { return web.isMediaSubscribed }
    return false
  }
  /// Whether this surface is presenting an unpaused lock screen or screen saver that
  /// reads system audio and needs live spectrum forwarding from the main app.
  var isLiveAudioEligible: Bool {
    guard !preview, !stopped, !rendererPaused, firstFrameReply == nil,
      isLivePresentationContent, scene.effectiveAudioResponseEnabled
    else { return false }
    if renderer != nil { return sceneRequiresAudio }
    if let web, contentError == nil { return web.isAudioSubscribed }
    return false
  }
  /// Display whose global bounds map cursor coordinates onto this surface.
  var pointerDisplayID: UInt32 { displayID ?? scene.displayID }
  /// Whether this surface is an active, unpaused lock-screen scene or web wallpaper that
  /// should react to cursor movement (parallax and hover effects). Never true for previews,
  /// unlocked desktop settle surfaces, screen savers, paused/held surfaces, or plain videos.
  var isLivePointerEligible: Bool {
    let kind: LockScreenPointerPolicy.SurfaceKind
    if renderer != nil {
      kind = .scene(acceptsPointerInput: sceneAcceptsPointerInput)
    } else if let web {
      kind = .web(ready: web.isReady, hasError: contentError != nil)
    } else if video != nil {
      kind = .video
    } else {
      kind = .none
    }
    return LockScreenPointerPolicy.isEligible(
      preview: preview, stopped: stopped, paused: rendererPaused,
      loading: firstFrameReply != nil, held: heldFailure != nil,
      content: content, kind: kind)
  }
  /// True when hover input can be delivered right now without racing web page suspension.
  var canDeliverPointerNow: Bool {
    guard isLivePointerEligible else { return false }
    if let web { return web.canDeliverPointer }
    return renderer != nil
  }
  /// True when this surface has not yet received its initial cursor state since becoming active.
  var needsInitialPointerSample: Bool {
    canDeliverPointerNow && pointerDelivery.entered == nil
  }
  var isSceneSurface: Bool { renderer != nil && !stopped }
  var isWebSurface: Bool { web != nil && !stopped && contentError == nil }
  private var layerHandoff = LockScreenSceneLayerHandoff()
  var pendingLayerRequest: LockScreenSceneLayerRequest? { layerHandoff.pendingRequest }
  /// When this surface started presenting, set once its first frame arrived.
  /// Kept apart from readiness so rendering one frame for a snapshot or a
  /// readiness reply cannot become a permanent right to keep rendering.
  private var presentingSince: ContinuousClock.Instant?
  private var previewExpiry: Task<Void, Never>?
  /// An explicit opt-in for a preview that has to keep animating. No host
  /// request sets it today; it exists so the bounded behaviour has a documented
  /// escape hatch rather than being unconditional.
  var continuousPreviewRequested = false
  private let counters: RuntimeCounters
  private var surfaceKey: RuntimeSurfaceKey {
    RuntimeSurfaceKey(
      kind: preview ? .preview : .lockScreen, displayID: scene.displayID, generation: generation)
  }
  private let generation: UInt64

  init(
    scene: LockScreenScene, displayID: UInt32?, size: CGSize, scale: CGFloat, preview: Bool,
    generation: UInt64 = 0, counters: RuntimeCounters? = nil
  ) throws {
    try Self.validate(size: size, scale: scale)
    self.scene = scene
    self.displayID = displayID
    self.size = size
    self.scale = scale
    self.preview = preview
    self.generation = generation
    self.counters = counters ?? .shared
    context = try WallpaperRuntime.context(displayID: displayID)
    root = CALayer()
    root.frame = CGRect(origin: .zero, size: size)
    root.contentsScale = scale
    context.layer = root
    CATransaction.flush()
  }

  private static func validate(size: CGSize, scale: CGFloat) throws {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite,
      size.width > 0, size.height > 0, scale > 0,
      size.width * scale <= 16_384, size.height * scale <= 16_384,
      size.width * size.height * scale * scale <= 32 * 1024 * 1024
    else { throw WallpaperRuntime.failure("Invalid wallpaper surface dimensions.") }
  }

  func start(completion: @escaping (Error?) -> Void) {
    guard !stopped, renderer == nil, web == nil, video == nil else {
      completion(WallpaperRuntime.failure("Wallpaper surface is not available."))
      return
    }
    do {
      let project = try WallpaperRuntime.asset(scene.projectPath)
      let assets = try WallpaperRuntime.asset(scene.assetsPath)
      contentError = nil
      if let entry = scene.webEntryFile {
        try startWeb(project: project, entry: entry, completion: completion)
        return
      }
      guard scene.fps > 0, (0...4).contains(scene.scalingMode), scene.scalingFactor.isFinite,
        scene.scalingFactor > 0, scene.framing?.isValid ?? true
      else {
        throw WallpaperRuntime.failure("Invalid lock-screen playback configuration.")
      }
      if scene.plainVideo == true {
        startVideo(completion: completion)
        return
      }
      try startEngine(project: project, assets: assets, completion: completion)
    } catch {
      completion(error)
      stop()
    }
  }

  /// The scene engine's start: its Metal layer, the renderer and its configuration.
  private func startEngine(
    project: URL, assets: URL, completion: @escaping (Error?) -> Void
  ) throws {
    let cache = WallpaperRuntime.documents.appendingPathComponent("ShaderCache")
      .appendingPathComponent(project.deletingLastPathComponent().lastPathComponent)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let metal = CAMetalLayer()
    metal.device = MTLCreateSystemDefaultDevice()
    metal.frame = root.bounds
    metal.contentsScale = scale
    metal.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
    metal.pixelFormat = .bgra8Unorm
    metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metal.framebufferOnly = false
    // An absent/purged drawable must reveal the committed frame underneath.
    metal.isOpaque = false
    guard metal.device != nil else {
      throw WallpaperRuntime.failure("Metal rendering is unavailable.")
    }
    root.addSublayer(metal)
    layer = metal
    CATransaction.flush()
    frameObserver = NotificationCenter.default.addObserver(
      forName: DesktopPosterNotification.ready, object: metal, queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated { self?.receive(notification) }
    }
    try check(owe_scene_wallpaper_new(&renderer))
    try check(owe_scene_wallpaper_init(renderer))
    // Lock-screen output stays SDR; the saved HDR processing quality is preserved.
    try check(owe_scene_wallpaper_set_display_hdr_output_allowed(renderer, false))
    try check(
      owe_scene_wallpaper_init_metal(
        renderer, Unmanaged.passUnretained(metal).toOpaque(), UInt32(metal.drawableSize.width),
        UInt32(metal.drawableSize.height), 0, 0, Double(scale)))
    // The lock-screen process never plays sound or forwards clicks/keyboard input; hover
    // cursor tracking, media integration and audio response stay off until `syncLiveCapabilities()`
    // confirms an active, unpaused lock-screen (or screen-saver, for media/audio) presentation.
    try check(
      owe_scene_wallpaper_set_property_bool(
        renderer, owe_property_audio_response_enabled(), false))
    // The scripts' localStorage as published with this revision, read-only (plan decision I3).
    if let path = scene.sceneStoragePath, let key = scene.sceneStorageScreenKey {
      let storage = try WallpaperRuntime.asset(path)
      try check(owe_scene_wallpaper_set_storage(renderer, storage.path, key, true))
    }
    // The saved scene quality, Wallpaper Engine options and effective render scale, in force for
    // the first frame. 2D scene resolution is intentionally never set here so the extension keeps
    // `Canvas size` within ExtensionKit memory limits.
    if let quality = scene.sceneQuality, let renderer {
      try check(SceneEngineOptionsBinding.apply(quality, to: renderer))
    }
    if let options = scene.engineOptions, let renderer {
      try check(SceneEngineOptionsBinding.apply(options, to: renderer))
    }
    let renderScale = scene.effectiveRenderScale
    if renderScale < 1.0 {
      try check(owe_scene_wallpaper_set_render_scale(renderer, renderScale))
    }
    try check(
      owe_scene_wallpaper_apply_config(
        renderer, project.path, assets.path, cache.path, scene.fps, false, 1, true, false,
        scene.propertiesJSON))
    try check(
      owe_scene_wallpaper_set_property_bool(
        renderer, owe_property_media_integration_enabled(), false))
    try check(
      owe_scene_wallpaper_set_property_int32(
        renderer, owe_property_scaling_mode(), scene.scalingMode))
    try check(
      owe_scene_wallpaper_set_property_float(
        renderer, owe_property_scaling_factor(), Float(scene.scalingFactor)))
    let framing = scene.effectiveFraming
    try check(owe_scene_wallpaper_set_framing(renderer, framing.panX, framing.panY))
    WallpaperRuntime.log(
      "Framing display=\(scene.displayID) panX=\(framing.panX) panY=\(framing.panY) renderScale=\(renderScale)")
    try installEngineSignals(renderer)
    firstFrameReply = completion
    requestFrame()
    armDeadline()
  }

  /// What the engine tells this surface without being asked, read when it does. A held scene never
  /// produces the poster the first frame waits for, so the engine's own first-frame edge, which it
  /// raises for a held failure too, is what ends that wait. A frame that fails after the scene drew has
  /// no poster to wait for and nothing to replace: the surface already shows the last frame.
  private enum EngineSignal { case firstFrame, renderFailed }

  private final class EngineSignalBox {
    let fire: () -> Void
    init(_ fire: @escaping () -> Void) { self.fire = fire }
  }

  private final class AudioRequirementBox {
    let fire: (Bool) -> Void
    init(_ fire: @escaping (Bool) -> Void) { self.fire = fire }
  }

  private final class PointerInputBox {
    let fire: (Bool) -> Void
    init(_ fire: @escaping (Bool) -> Void) { self.fire = fire }
  }

  private func installEngineSignals(_ renderer: OpaquePointer?) throws {
    func callback(_ signal: EngineSignal) -> UnsafeMutableRawPointer {
      Unmanaged.passRetained(
        EngineSignalBox { [weak self] in
          Task { @MainActor in self?.engineSignalled(signal) }
        }
      ).toOpaque()
    }
    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      if let pointer { Unmanaged<EngineSignalBox>.fromOpaque(pointer).release() }
    }
    let fire: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      guard let pointer else { return }
      Unmanaged<EngineSignalBox>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    let first = callback(.firstFrame)
    let firstResult = owe_scene_wallpaper_set_first_frame_callback(renderer, fire, first, drop)
    // A refusal does not take ownership of the box.
    if firstResult != 0 { drop(first) }
    try check(firstResult)
    let failed = callback(.renderFailed)
    let failedResult = owe_scene_wallpaper_set_render_failure_callback(renderer, fire, failed, drop)
    if failedResult != 0 { drop(failed) }
    try check(failedResult)

    let audioBox = Unmanaged.passRetained(
      AudioRequirementBox { [weak self] required in
        Task { @MainActor in self?.audioRequirementChanged(required) }
      }
    ).toOpaque()
    let audioFire: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { pointer, required in
      guard let pointer else { return }
      Unmanaged<AudioRequirementBox>.fromOpaque(pointer).takeUnretainedValue().fire(required)
    }
    let audioDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      if let pointer { Unmanaged<AudioRequirementBox>.fromOpaque(pointer).release() }
    }
    let audioResult = owe_scene_wallpaper_set_audio_requirement_callback(
      renderer, audioFire, audioBox, audioDrop)
    if audioResult != 0 { audioDrop(audioBox) }
    try check(audioResult)

    let pointerBox = Unmanaged.passRetained(
      PointerInputBox { [weak self] accepts in
        Task { @MainActor in self?.pointerInputCapabilityChanged(accepts) }
      }
    ).toOpaque()
    let pointerFire: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { pointer, accepts in
      guard let pointer else { return }
      Unmanaged<PointerInputBox>.fromOpaque(pointer).takeUnretainedValue().fire(accepts)
    }
    let pointerDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
      if let pointer { Unmanaged<PointerInputBox>.fromOpaque(pointer).release() }
    }
    let pointerResult = owe_scene_wallpaper_set_pointer_input_callback(
      renderer, pointerFire, pointerBox, pointerDrop)
    if pointerResult != 0 { pointerDrop(pointerBox) }
    try check(pointerResult)
  }

  private func audioRequirementChanged(_ required: Bool) {
    guard !stopped, renderer != nil, sceneRequiresAudio != required else { return }
    sceneRequiresAudio = required
    syncLiveCapabilities()
  }

  private func pointerInputCapabilityChanged(_ accepts: Bool) {
    guard !stopped, renderer != nil, sceneAcceptsPointerInput != accepts else { return }
    if !accepts { clearPointerState() }
    sceneAcceptsPointerInput = accepts
    syncLiveCapabilities()
  }

  private func engineSignalled(_ signal: EngineSignal) {
    guard !stopped, renderer != nil, let held = engineHeldFailure() else { return }
    settleHeld(held, afterSignal: signal)
  }

  /// The engine's reason for holding this scene, when it is held.
  private func engineHeldFailure() -> LockScreenHeldFailure? {
    guard let renderer else { return nil }
    let scene = UnsafeMutableRawPointer(renderer)
    var reason = ""
    let needed = owe_scene_wallpaper_backend_failure_reason(scene, nil, 0)
    if needed > 0 {
      var buffer = [CChar](repeating: 0, count: needed + 1)
      _ = owe_scene_wallpaper_backend_failure_reason(scene, &buffer, buffer.count)
      reason = String(cString: buffer)
    }
    return LockScreenHeldFailure(rawStage: owe_scene_wallpaper_backend_failure(scene), reason: reason)
  }

  /// Native Metal could not draw the scene, or no player could play the video. Said once, in the log and in
  /// the readiness the app reads; the surface keeps its last frame, or shows the engine's preview picture.
  private func settleHeld(_ held: LockScreenHeldFailure, afterSignal signal: EngineSignal) {
    guard heldFailure == nil else { return }
    heldFailure = held
    heldNotice = Self.heldMessage(held)
    WallpaperRuntime.log(
      "Held display=\(scene.displayID) \(held.logDetail); not drawn, holding the last frame or the preview picture")
    switch signal {
    case .firstFrame:
      // The picture the wait was for is the one on the surface, so the wait is over. The preview, when
      // the project has one, is a sublayer the engine put on this surface's layer.
      guard let reply = firstFrameReply else { break }
      firstFrameReply = nil
      deadline?.cancel()
      deadline = nil
      presentingSince = ContinuousClock.now
      applyPolicy()
      reply(nil)
      let waiters = readyWaiters
      readyWaiters.removeAll()
      waiters.forEach { $0(nil) }
      finishSnapshots(error: latestSnapshot == nil ? WallpaperRuntime.failure("Wallpaper frame is not ready.") : nil)
    case .renderFailed:
      // After the scene drew: nothing to replace. The note reaches the app with the next readiness.
      if pendingLayerRequest != nil {
        layerHandoff = LockScreenSceneLayerHandoff()
        WallpaperController.shared.reconcileLiveFeed()
      }
      WallpaperController.shared.acknowledge(surface: self)
    }
  }

  /// The words the app shows for a held scene, in the extension's language.
  static func heldMessage(_ held: LockScreenHeldFailure) -> String {
    let stage: String
    switch held.stage {
    case .unsupported: stage = String(localized: "it uses something Native Metal can't draw")
    case .prepare: stage = String(localized: "Native Metal couldn't start")
    case .compile: stage = String(localized: "its shaders didn't compile for Metal")
    case .frame: stage = String(localized: "a frame failed in Native Metal")
    case .surface: stage = String(localized: "Native Metal couldn't take the new display")
    case .video:
      return String(
        localized: "This video can't be played: \(held.reason). The lock screen keeps its last frame.")
    }
    let detail = held.reason.isEmpty ? stage : stage + " " + String(localized: "(reason: \(held.reason))")
    return String(
      localized:
        "Native Metal can't draw this wallpaper: \(detail). The lock screen shows its last frame, or its preview picture when it has drawn nothing yet."
    )
  }

  private func armDeadline() {
    deadline?.cancel()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, let reply = self.firstFrameReply else { return }
      self.firstFrameReply = nil
      reply(
        WallpaperRuntime.failure(
          "The lock-screen renderer did not produce a frame within 30 seconds."))
      self.stop()
    }
  }

  /// What the attempt to play the clip came to: a player showing its first frame, or the reason no
  /// player of the app's own could take it.
  private enum VideoAttempt {
    case unplayable(reason: String)
    case ready(LockScreenVideoPlaying, CGImage)
  }

  /// A plain video: decided against the same admission rule the desktop uses and played by the
  /// extension's own players, an AVFoundation layer or the WebM player. There is no other renderer for
  /// a video, so a clip they cannot take, before the first frame or after it, is held and reported.
  /// The attempt, from the decision to the first frame, has its own deadline, so a player that neither
  /// shows a frame nor fails is reported while the host is still waiting.
  private func startVideo(completion: @escaping (Error?) -> Void) {
    firstFrameReply = completion
    armDeadline()
    let scene = scene
    nativeStart = Task { @MainActor [weak self] in
      guard let self else { return }
      let attempt: VideoAttempt
      do {
        attempt = try await LockScreenDeadline.run(within: LockScreenDeadline.nativeAttempt) {
          [weak self] in
          guard let self else { throw CancellationError() }
          return try await self.attemptVideo(scene: scene)
        }
      } catch {
        guard !Task.isCancelled, !self.stopped, self.firstFrameReply != nil else { return }
        self.video?.stop()
        self.video = nil
        self.holdVideo(error.localizedDescription)
        return
      }
      guard !Task.isCancelled, !self.stopped, self.firstFrameReply != nil else {
        if case .ready(let player, _) = attempt, self.video !== player { player.stop() }
        return
      }
      switch attempt {
      case .unplayable(let reason):
        self.holdVideo(reason)
      case .ready(let player, let first):
        guard self.video === player else { return }
        do {
          let snapshot = try Self.snapshot(first)
          try LockScreenFrameBacking.install(snapshot, on: self.root)
          self.latestSnapshot = snapshot
        } catch {
          player.stop()
          self.video = nil
          self.holdVideo(error.localizedDescription)
          return
        }
        self.contentFrameReady()
        self.finishSnapshots(error: nil)
        // Last, so a failure the player already held is heard once the surface is ready for it.
        player.onFailure = { [weak self] detail in
          MainActor.assumeIsolated { self?.videoDidFail(detail) }
        }
      }
    }
  }

  private func attemptVideo(scene: LockScreenScene) async throws -> VideoAttempt {
    let path = await LockScreenVideoPlanner.decide(
      scene: scene, resolve: { try WallpaperRuntime.asset($0) })
    try Task.checkCancellation()
    let framing = scene.effectiveFraming
    let mode = NativeVideoScalingMode(rendererValue: scene.scalingMode) ?? .fill
    let pan = NativeVideoLayout.Pan(x: framing.panX, y: framing.panY)
    let player: LockScreenVideoPlaying
    let options = scene.engineOptions ?? .identity
    let lut = scene.lutFile.flatMap { try? WallpaperRuntime.asset($0) }.flatMap(VideoLutLoader.load)
    let border = scene.borderCGColor
    switch path {
    case .avFoundation(let url):
      player = LockScreenVideoPlayer(
        url: url, mode: mode, factor: scene.scalingFactor, pan: pan, viewport: size,
        backingScale: self.scale, options: options, lut: lut, borderColor: border)
    case .webM(_, let file):
      player = LockScreenWebMPlayer(
        file: file, mode: mode, factor: scene.scalingFactor, pan: pan, viewport: size,
        backingScale: self.scale, options: options, lut: lut, borderColor: border)
    case .unplayable(let reason):
      return .unplayable(reason: reason)
    }
    video = player
    player.attach(to: root)
    do {
      guard let first = try await player.prepare() else {
        throw LockScreenVideoPlayer.Failure.unplayable("no frame could be read from the clip")
      }
      try Task.checkCancellation()
      return .ready(player, first)
    } catch {
      // Stopped here, not by the caller, which may have moved on to another player.
      player.stop()
      if video === player { video = nil }
      if error is CancellationError || (error as? LockScreenVideoPlayer.Failure) == .stopped {
        throw error
      }
      return .unplayable(reason: error.localizedDescription)
    }
  }

  /// The clip cannot be played and nothing else draws a video: the surface keeps the frame it shows
  /// (nothing, when it never had one) and says why, in the log and in the readiness the app reads. The
  /// host is told a picture exists even then, because it would otherwise wait out its whole deadline.
  private func holdVideo(_ reason: String) {
    nativeStart = nil
    guard !stopped else { return }
    settleHeld(
      LockScreenHeldFailure(video: reason),
      afterSignal: firstFrameReply != nil ? .firstFrame : .renderFailed)
  }

  /// The player stopped being able to play a clip it was playing. The frame it left on the surface
  /// stays, and the failure is reported.
  private func videoDidFail(_ detail: String) {
    guard !stopped, video != nil else { return }
    video?.stop()
    video = nil
    holdVideo(detail)
  }

  private func check(_ result: Int32) throws {
    guard result != 0 else { return }
    let message =
      owe_last_error().map { String(cString: $0) } ?? String(localized: "Unknown native rendering error.")
    throw WallpaperRuntime.failure(detail: message)
  }

  private func requestFrame() {
    if let layer {
      NotificationCenter.default.post(
        name: DesktopPosterNotification.request, object: layer)
    }
  }

  private func receive(_ notification: Notification) {
    guard !stopped, let frame = DesktopPosterFrame(userInfo: notification.userInfo) else { return }
    do {
      let snapshot = try Self.snapshot(frame.pixels, width: frame.width, height: frame.height, bgra: frame.bgra)
      try LockScreenFrameBacking.install(snapshot, on: root)
      latestSnapshot = snapshot
      contentFrameReady()
      finishSnapshots(error: nil)
    } catch {
      if let reply = firstFrameReply {
        firstFrameReply = nil
        reply(error)
        stop()
      }
      finishSnapshots(error: error)
    }
  }
  private func contentFrameReady() {
    guard let reply = firstFrameReply else { return }
    firstFrameReply = nil
    deadline?.cancel()
    deadline = nil
    presentingSince = ContinuousClock.now
    logBackend()
    counters.record(.readinessFrameRendered, for: surfaceKey)
    applyPolicy()
    reply(nil)
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(nil) }
  }

  /// Which backend drew the first frame. The backend is only known once the scene is parsed, which the
  /// first frame proves.
  private func logBackend() {
    if video != nil {
      WallpaperRuntime.log(
        "Backend display=\(scene.displayID) drew=\(video is LockScreenWebMPlayer ? "WebM video" : "AVFoundation video")")
      return
    }
    guard let renderer else { return }
    let backend =
      owe_scene_wallpaper_backend(UnsafeMutableRawPointer(renderer))
        == Int32(OWE_SCENE_BACKEND_NATIVE_METAL.rawValue) ? "native Metal" : "unknown"
    WallpaperRuntime.log("Backend display=\(scene.displayID) drew=\(backend)")
  }

  private func startWeb(project: URL, entry: String, completion: @escaping (Error?) -> Void) throws {
    let page = try ScreenSaverWebSurface(
      projectURL: project.deletingLastPathComponent(), entryFile: entry,
      readAccessURL: project.deletingLastPathComponent(),
      size: size, scale: scale, propertiesJSON: scene.propertiesJSON ?? "{}", fps: scene.fps,
      // The page renders its readiness frame live, as a scene or a clip does; `applyPolicy`
      // pauses it after that frame. Created paused it would hold its first frame while this
      // surface counted it as playing, and the settling desktop and a lock in its first
      // seconds would never resume it.
      paused: rendererPaused,
      renderScale: scene.effectiveRenderScale,
      language: scene.effectiveLanguage,
      mediaIntegrationEnabled: desiredWebMediaEnabled,
      audioResponseEnabled: !preview && isLivePresentationContent && scene.effectiveAudioResponseEnabled)
    web = page
    firstFrameReply = completion
    page.onAudioSubscriptionChanged = { [weak self] _ in
      self?.syncLiveCapabilities()
    }
    page.onMediaSubscriptionChanged = { [weak self] subscribed in
      guard let self else { return }
      self.syncLiveCapabilities()
      if subscribed, self.isLiveMediaEligible {
        WallpaperController.shared.replayMedia(to: self)
      }
    }
    page.onBecameActive = { [weak self] in
      guard let self else { return }
      if self.isLiveMediaEligible {
        WallpaperController.shared.replayMedia(to: self)
      }
      WallpaperController.shared.reconcileLiveFeed()
      WallpaperController.shared.refreshPointerIfNeeded()
    }
    page.onFrame = { [weak self] image in
      guard let self, !self.stopped else { throw CancellationError() }
      guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ScreenSaverWebSurface.Failure.noFrame
      }
      let frame = try Self.snapshot(pixels)
      try LockScreenFrameBacking.install(frame, on: self.root)
      self.latestSnapshot = frame
    }
    page.onFailure = { [weak self] error in
      guard let self, !self.stopped else { return }
      self.contentError = error
      let waiters = self.readyWaiters
      self.readyWaiters.removeAll()
      waiters.forEach { $0(error) }
      self.finishSnapshots(error: error)
      WallpaperController.shared.acknowledge(surface: self, error: error)
    }
    try page.attach(to: root)
    page.start { [weak self] error in
      guard let self, !self.stopped else { return }
      if let error {
        self.contentError = error
        let reply = self.firstFrameReply
        self.firstFrameReply = nil
        reply?(error)
      } else {
        self.contentFrameReady()
      }
    }
  }


  private static func snapshot(_ data: Data, width: Int, height: Int, bgra: Bool) throws
    -> IOSurface
  {
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
      width * height <= 32 * 1024 * 1024, data.count == width * height * 4,
      let provider = CGDataProvider(data: data as CFData)
    else { throw CocoaError(.fileReadCorruptFile) }
    let bitmap =
      bgra
      ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
      : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw CocoaError(.fileReadCorruptFile) }
    return try snapshot(image)
  }

  private static func snapshot(_ image: CGImage) throws -> IOSurface {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, width <= 16_384, height <= 16_384,
      width * height <= 32 * 1024 * 1024,
      let surface = IOSurface(properties: [
        .width: width, .height: height, .bytesPerElement: 4,
        .pixelFormat: kCVPixelFormatType_32BGRA,
      ])
    else { throw CocoaError(.fileReadCorruptFile) }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard
      let target = CGContext(
        data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw CocoaError(.fileReadCorruptFile) }
    target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return surface
  }

  func update(scene: LockScreenScene) {
    let previousRenderScale = self.scene.effectiveRenderScale
    self.scene = scene
    if let renderer {
      do { try check(owe_scene_wallpaper_set_target_fps(renderer, scene.fps)) } catch {
        WallpaperRuntime.log(error.localizedDescription)
      }
      if scene.effectiveRenderScale != previousRenderScale {
        do { try check(owe_scene_wallpaper_set_render_scale(renderer, scene.effectiveRenderScale)) } catch {
          WallpaperRuntime.log(error.localizedDescription)
        }
      }
    }
    if let web {
      do {
        // The page keeps the state this surface tracks; `applyPolicy` below changes both together.
        try web.update(propertiesJSON: scene.propertiesJSON ?? "{}", fps: scene.fps,
          paused: rendererPaused, renderScale: scene.effectiveRenderScale,
          language: scene.effectiveLanguage)
      } catch {
        contentError = error
        web.stop()
        WallpaperController.shared.acknowledge(surface: self, error: error)
      }
    }
    applyPolicy()
  }

  /// Presentation eligibility for this surface, decided by the rules both
  /// processes share. A preview is bounded in time: producing the readiness
  /// frame must not buy it the right to animate for as long as a settings
  /// window happens to stay open.
  private var authorityRequest: WallpaperPresentationAuthority.Request {
    // Native desktop holds a frame once it has settled; the ordinary desktop renderer remains live.
    let session = WallpaperPresentationAuthority.SessionState.current()
    return WallpaperPresentationAuthority.Request(
      role: preview ? .preview : .lockScreen,
      userPaused: scene.paused,
      displaysAsleep: WallpaperController.shared.displayPower.displaysAsleep(for: displayID),
      sessionLocked: session.locked,
      sessionOnConsole: session.onConsole,
      presentationMode: presentation,
      hostActivity: activity == "suspended" ? .suspended : .active,
      presentedFor: presentingSince.map { ContinuousClock.now - $0 },
      continuousPreviewRequested: continuousPreviewRequested,
      lockScreenEnabled: WallpaperController.shared.configuration?.scene(for: .lockScreen, displayID: displayID) != nil,
      screenSaverEnabled: WallpaperController.shared.configuration?.scene(for: .screenSaver, displayID: displayID) != nil)
  }

  var mayReplaceContent: Bool {
    WallpaperPresentationAuthority.mayPrepareReplacement(
      authorityRequest, hasPendingAcquire: pendingAcquires.hasPending)
  }

  func applyPolicy() {
    guard firstFrameReply == nil, !stopped, renderer != nil || web != nil || video != nil else {
      return
    }
    defer { syncLiveCapabilities() }
    let request = authorityRequest
    layerHandoff.update(scene: scene, content: content, configuration: WallpaperController.shared.configuration,
      presentation: request, rendererReady: renderer != nil && presentingSince != nil && heldFailure == nil)
    // Keep the last drawable and scene state through unlock/sleep. Replacing
    // them with a poster forces a cold load after the display is already lit.
    let reasons = WallpaperPresentationAuthority.suspensionReasons(for: request)
    let shouldPause = !reasons.isEmpty
    schedulePreviewExpiry(for: request)
    guard shouldPause != rendererPaused else { return }
    if shouldPause { clearPointerState() }
    do {
      if let web {
        web.setPaused(shouldPause)
      } else if let video {
        video.setPaused(shouldPause)
      } else if let renderer {
        try check(owe_scene_wallpaper_set_paused(renderer, shouldPause))
      }
      rendererPaused = shouldPause
      // The held frame becomes what snapshots and the backing show, in place of
      // the readiness frame (often an intro's black opening).
      if shouldPause, renderer != nil { requestFrame() }
      if shouldPause, video != nil { refreshVideoFrame() }
      counters.record(shouldPause ? .presentationSuspended : .presentationAuthorized, for: surfaceKey)
      WallpaperRuntime.log(
        "Playback display=\(scene.displayID) mode=\(presentation) activity=\(activity) locked=\(request.sessionLocked) console=\(request.sessionOnConsole) paused=\(shouldPause) reasons=\(reasons.rawValue)"
      )
    } catch { WallpaperRuntime.log(error.localizedDescription) }
  }

  func applyLayerState(from states: [UUID: String]) -> Bool {
    guard let renderer, let state = layerHandoff.takeState(from: states) else { return false }
    do { try check(owe_scene_wallpaper_apply_layer_state(renderer, state)) }
    catch { WallpaperRuntime.log("Scene layer handoff failed: \(error.localizedDescription)") }
    return true
  }

  /// Syncs live media-integration and audio-response switches on the running scene or
  /// web surface and updates `WallpaperController`'s aggregate demand.
  func syncLiveCapabilities() {
    if let renderer {
      let wantAudio = isLiveAudioEligible
      if appliedAudioResponseEnabled != wantAudio {
        appliedAudioResponseEnabled = wantAudio
        _ = owe_scene_wallpaper_set_property_bool(
          renderer, owe_property_audio_response_enabled(), wantAudio)
      }
      let wantMedia = isLiveMediaEligible
      if appliedMediaIntegrationEnabled != wantMedia {
        if !wantMedia {
          if let status = LockScreenMediaCodec.sceneStatusJSON(enabled: false) {
            _ = owe_scene_wallpaper_submit_media_event_json(renderer, status)
          }
          _ = owe_scene_wallpaper_apply_system_media_artwork(renderer, 0, 0, nil, 0)
        }
        appliedMediaIntegrationEnabled = wantMedia
        _ = owe_scene_wallpaper_set_property_bool(
          renderer, owe_property_media_integration_enabled(), wantMedia)
        lastDeliveredMediaGeneration = 0
        lastDeliveredArtworkRevision = 0
        if wantMedia {
          if let status = LockScreenMediaCodec.sceneStatusJSON(enabled: true) {
            _ = owe_scene_wallpaper_submit_media_event_json(renderer, status)
          }
          WallpaperController.shared.replayMedia(to: self)
        }
      }
    } else if let web {
      let wantWebMedia = desiredWebMediaEnabled
      let wantWebAudio = isLiveAudioEligible
      web.setMediaIntegrationEnabled(wantWebMedia)
      web.setAudioResponseEnabled(wantWebAudio)
      if !wantWebAudio {
        web.setLiveAudioActive(false)
      }
      let wantLiveMedia = isLiveMediaEligible
      if appliedMediaIntegrationEnabled != wantLiveMedia {
        appliedMediaIntegrationEnabled = wantLiveMedia
        lastDeliveredMediaGeneration = 0
        lastDeliveredArtworkRevision = 0
        if wantLiveMedia {
          WallpaperController.shared.replayMedia(to: self)
        }
      }
      appliedAudioResponseEnabled = wantWebAudio
    }
    if !isLivePointerEligible {
      clearPointerState()
    }
    WallpaperController.shared.reconcileLiveFeed()
  }

  /// Delivers one global CoreGraphics cursor sample into this lock-screen surface, deduplicating
  /// unchanged positions and enter/leave transitions. Never delivers clicks or keyboard input.
  func deliverPointer(cursor: CGPoint, in bounds: CGRect?) {
    guard canDeliverPointerNow else { return }
    guard let bounds else {
      clearPointerState()
      return
    }
    let update = pointerDelivery.update(cursor: cursor, in: bounds)
    guard !update.isEmpty else { return }
    if let renderer {
      if let entered = update.entered {
        _ = owe_scene_wallpaper_mouse_enter(renderer, entered)
      }
      if let position = update.position {
        _ = owe_scene_wallpaper_mouse_input(renderer, position.x, position.y)
      }
      counters.record(.pointerDelivered, for: surfaceKey)
    } else if let web {
      if let position = update.position {
        if web.deliverPointerMove(normalizedX: position.x, normalizedY: position.y) {
          counters.record(.pointerDelivered, for: surfaceKey)
        }
      } else if update.entered == false {
        web.deliverPointerExit()
        counters.record(.pointerDelivered, for: surfaceKey)
      }
    }
  }

  /// Leaves hover cleanly when this surface pauses, unlocks, sleeps, or switches away from
  /// an active lock-screen presentation.
  func clearPointerState() {
    guard pointerDelivery.exit() else { return }
    if let renderer {
      _ = owe_scene_wallpaper_mouse_enter(renderer, false)
    } else if let web {
      web.deliverPointerExit()
    }
  }

  func deliverMedia(
    snapshot: LockScreenMediaSnapshot,
    artworkRGBA: Data?,
    artworkPNGDataURL: String,
    timelineAt now: Date,
    forceReplay: Bool
  ) {
    guard isLiveMediaEligible else { return }
    guard forceReplay || snapshot.generation != lastDeliveredMediaGeneration else { return }
    lastDeliveredMediaGeneration = snapshot.generation

    if let renderer {
      if let status = LockScreenMediaCodec.sceneStatusJSON(enabled: true) {
        _ = owe_scene_wallpaper_submit_media_event_json(renderer, status)
      }
      if let props = LockScreenMediaCodec.scenePropertiesJSON(snapshot.properties) {
        _ = owe_scene_wallpaper_submit_media_event_json(renderer, props)
      }
      if let thumb = snapshot.thumbnail {
        if forceReplay || thumb.artworkRevision != lastDeliveredArtworkRevision {
          lastDeliveredArtworkRevision = thumb.artworkRevision
          if let rgba = artworkRGBA, thumb.width > 0, thumb.height > 0 {
            rgba.withUnsafeBytes { raw in
              let pointer = raw.bindMemory(to: UInt8.self).baseAddress
              _ = owe_scene_wallpaper_apply_system_media_artwork(
                renderer, UInt32(thumb.width), UInt32(thumb.height), pointer, UInt(rgba.count))
            }
          } else {
            _ = owe_scene_wallpaper_apply_system_media_artwork(renderer, 0, 0, nil, 0)
          }
        }
        if let thumbJSON = LockScreenMediaCodec.sceneThumbnailJSON(thumb) {
          _ = owe_scene_wallpaper_submit_media_event_json(renderer, thumbJSON)
        }
      } else if forceReplay || lastDeliveredArtworkRevision != 0 {
        lastDeliveredArtworkRevision = 0
        _ = owe_scene_wallpaper_apply_system_media_artwork(renderer, 0, 0, nil, 0)
      }
      if let playback = LockScreenMediaCodec.scenePlaybackJSON(webRawState: snapshot.playbackState) {
        _ = owe_scene_wallpaper_submit_media_event_json(renderer, playback)
      }
      if let timeline = snapshot.interpolatedTimeline(at: now),
        let timelineJSON = LockScreenMediaCodec.sceneTimelineJSON(
          position: timeline.position, duration: timeline.duration)
      {
        _ = owe_scene_wallpaper_submit_media_event_json(renderer, timelineJSON)
      }
    } else if let web {
      var events: [(slot: String, payload: [String: Any])] = [
        ("status", ["enabled": true]),
        ("properties", LockScreenMediaCodec.webPropertiesPayload(snapshot.properties)),
      ]
      if let thumb = snapshot.thumbnail {
        events.append((
          "thumbnail",
          LockScreenMediaCodec.webThumbnailPayload(thumb, dataURL: artworkPNGDataURL)
        ))
      }
      events.append((
        "playback",
        LockScreenMediaCodec.webPlaybackPayload(webRawState: snapshot.playbackState)
      ))
      if let timeline = snapshot.interpolatedTimeline(at: now) {
        events.append((
          "timeline",
          LockScreenMediaCodec.webTimelinePayload(
            position: timeline.position, duration: timeline.duration)
        ))
      }
      web.deliverMediaEvents(events)
    }
  }

  func deliverTimelineTick(position: Double, duration: Double) {
    guard isLiveMediaEligible else { return }
    if let renderer {
      if let json = LockScreenMediaCodec.sceneTimelineJSON(position: position, duration: duration) {
        _ = owe_scene_wallpaper_submit_media_event_json(renderer, json)
      }
    } else if let web {
      web.deliverMediaEvents([
        ("timeline", LockScreenMediaCodec.webTimelinePayload(position: position, duration: duration))
      ])
    }
  }

  func deliverWebAudio(bins: [Double]?, liveActive: Bool) {
    guard let web else { return }
    guard isLiveAudioEligible else {
      web.setLiveAudioActive(false)
      return
    }
    web.setLiveAudioActive(liveActive)
    if let bins {
      web.deliverAudio(bins)
    }
  }

  /// Re-evaluates a preview when its budget runs out, or a desktop when it has
  /// settled, so it stops on its own rather than waiting for a host update that
  /// may never come.
  private func schedulePreviewExpiry(for request: WallpaperPresentationAuthority.Request) {
    previewExpiry?.cancel()
    previewExpiry = nil
    guard let remaining = WallpaperPresentationAuthority.nextReevaluation(for: request) else {
      return
    }
    previewExpiry = Task { [weak self] in
      do { try await Task.sleep(for: remaining) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.previewExpiry = nil
      self.applyPolicy()
    }
  }

  /// The held frame of a paused clip becomes what snapshots and the backing show, in place of
  /// the frame it opened with.
  private func refreshVideoFrame() {
    guard let video else { return }
    Task { @MainActor [weak self, weak video] in
      guard let self, let video, self.video === video, self.rendererPaused,
        let frame = await video.frame(), self.video === video, self.rendererPaused,
        let snapshot = try? Self.snapshot(frame)
      else { return }
      try? LockScreenFrameBacking.install(snapshot, on: self.root)
      self.latestSnapshot = snapshot
    }
  }

  func snapshot(reply: @escaping (Any?, Error?) -> Void) {
    if let web, !web.isPaused, !rendererPaused, !stopped {
      web.snapshot { [weak self] result in
        guard let self else { reply(nil, CancellationError()); return }
        do {
          let image = try result.get()
          guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenSaverWebSurface.Failure.noFrame
          }
          let frame = try Self.snapshot(pixels)
          self.latestSnapshot = frame
          reply(try WallpaperRuntime.snapshotReply(frame), nil)
        } catch { reply(nil, error) }
      }
      return
    }
    if let video, !rendererPaused, !stopped {
      Task { @MainActor [weak self] in
        guard let self else { reply(nil, CancellationError()); return }
        do {
          if let frame = await video.frame(), !self.stopped {
            let snapshot = try Self.snapshot(frame)
            self.latestSnapshot = snapshot
          }
          guard let latest = self.latestSnapshot else {
            throw WallpaperRuntime.failure("Wallpaper frame is not ready.")
          }
          reply(try WallpaperRuntime.snapshotReply(latest), nil)
        } catch { reply(nil, error) }
      }
      return
    }
    if rendererPaused || stopped {
      do {
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper frame is not ready.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
      return
    }
    snapshotWaiters.append(reply)
    requestFrame()
    guard snapshotDeadline == nil else { return }
    snapshotDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      // A frame already known to have been presented is safe if rendering paused meanwhile.
      self?.finishSnapshots(
        error: self?.latestSnapshot == nil
          ? WallpaperRuntime.failure("Wallpaper snapshot timed out.") : nil)
    }
  }

  private func finishSnapshots(error: Error?) {
    snapshotDeadline?.cancel()
    snapshotDeadline = nil
    let waiters = snapshotWaiters
    snapshotWaiters.removeAll()
    for reply in waiters {
      do {
        if let error { throw error }
        guard let latestSnapshot else {
          throw WallpaperRuntime.failure("Wallpaper snapshot is unavailable.")
        }
        reply(try WallpaperRuntime.snapshotReply(latestSnapshot), nil)
      } catch { reply(nil, error) }
    }
  }

  func whenReady(_ reply: @escaping (Error?) -> Void) {
    if stopped {
      reply(CancellationError())
    } else if let contentError {
      reply(contentError)
    } else if latestSnapshot != nil, firstFrameReply == nil {
      reply(nil)
    } else if heldFailure != nil, firstFrameReply == nil {
      // Held, with a picture on the surface but no snapshot of it: that is as ready as it will get.
      reply(nil)
    } else {
      readyWaiters.append(reply)
    }
  }

  func replace(
    scene: LockScreenScene, size: CGSize, scale: CGFloat,
    completion: @escaping (Error?) -> Void
  ) {
    guard !stopped else {
      completion(CancellationError())
      return
    }
    do { try Self.validate(size: size, scale: scale) } catch {
      completion(error)
      return
    }
    releaseRenderer(keepingFrame: true)
    self.scene = scene
    self.size = size
    self.scale = scale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    root.frame = CGRect(origin: .zero, size: size)
    root.contentsScale = scale
    CATransaction.commit()
    rendererPaused = false
    start(completion: completion)
  }

  private func releaseRenderer(keepingFrame: Bool = false) {
    layerHandoff = LockScreenSceneLayerHandoff()
    deadline?.cancel()
    deadline = nil
    previewExpiry?.cancel()
    previewExpiry = nil
    presentingSince = nil
    if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    frameObserver = nil
    web?.stop()
    web = nil
    nativeStart?.cancel()
    nativeStart = nil
    video?.stop()
    video = nil
    contentError = nil
    heldFailure = nil
    heldNotice = nil
    if let renderer {
      _ = owe_scene_wallpaper_begin_surface_reconfigure(renderer)
      _ = owe_scene_wallpaper_shutdown(renderer)
      _ = owe_scene_wallpaper_delete(renderer)
    }
    renderer = nil
    layer?.removeFromSuperlayer()
    layer = nil
    if let reply = firstFrameReply {
      firstFrameReply = nil
      reply(CancellationError())
    }
    rendererPaused = true
    sceneRequiresAudio = false
    sceneAcceptsPointerInput = true
    pointerDelivery.reset()
    appliedMediaIntegrationEnabled = false
    appliedAudioResponseEnabled = false
    lastDeliveredMediaGeneration = 0
    lastDeliveredArtworkRevision = 0
    let waiters = readyWaiters
    readyWaiters.removeAll()
    waiters.forEach { $0(CancellationError()) }
    finishSnapshots(error: CancellationError())
    latestSnapshot = nil
    if !keepingFrame { root.contents = nil }
    WallpaperController.shared.reconcileLiveFeed()
  }

  func clear() {
    pendingAcquires.cancel()
    releaseRenderer()
    CATransaction.flush()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    pendingAcquires.cancel()
    releaseRenderer()
    context.invalidate()
  }
}
