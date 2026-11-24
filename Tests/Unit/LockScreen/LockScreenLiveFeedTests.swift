import Foundation
import XCTest

@testable import WallpaperMachine

@MainActor
final class LockScreenLiveFeedTests: XCTestCase {
  private var exchangeURL: URL!

  override func setUpWithError() throws {
    exchangeURL = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("lockscreen-live-feed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: exchangeURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: exchangeURL)
  }

  // MARK: - LockScreenAudioSpectrumChannel

  func testAudioSpectrumChannelRoundTrips224UnclampedBandsAndClampsWebBins() {
    let writer = LockScreenAudioSpectrumWriter(exchange: exchangeURL)
    let reader = LockScreenAudioSpectrumReader(exchange: exchangeURL)
    defer {
      reader.close()
      writer.deactivate(removeFile: true)
    }

    var bands = [Float](repeating: 0, count: LockScreenAudioSpectrumChannel.bandCount)
    bands[0] = 1.65
    bands[63] = -0.25
    bands[64] = 0.75
    bands[127] = .nan
    bands[128] = 1.35
    bands[223] = 0.42

    let t0: UInt64 = 10_000_000_000
    XCTAssertTrue(writer.write(generation: 7, stereo: true, bands: bands, nowNanos: t0))

    let frame = reader.read(nowNanos: t0 + 10_000_000)
    XCTAssertNotNil(frame)
    XCTAssertEqual(frame?.generation, 7)
    XCTAssertEqual(frame?.stereo, true)
    XCTAssertEqual(frame?.bands.count, 224)
    XCTAssertEqual(frame?.bands[0] ?? 0, 1.65, accuracy: 1e-6)
    XCTAssertEqual(frame?.bands[128] ?? 0, 1.35, accuracy: 1e-6)
    XCTAssertEqual(frame?.bands[223] ?? 0, 0.42, accuracy: 1e-6)

    let webBins = frame?.clampedWebBins128() ?? []
    XCTAssertEqual(webBins.count, 128)
    XCTAssertEqual(webBins[0], 1.0, accuracy: 1e-6)
    XCTAssertEqual(webBins[63], 0.0, accuracy: 1e-6)
    XCTAssertEqual(webBins[64], 0.75, accuracy: 1e-6)
    XCTAssertEqual(webBins[127], 0.0, accuracy: 1e-6)
  }

  func testAudioSpectrumChannelExpiresWhenStaleAndRecoversAfterFileReplacement() {
    let writer = LockScreenAudioSpectrumWriter(exchange: exchangeURL)
    let reader = LockScreenAudioSpectrumReader(exchange: exchangeURL)
    defer {
      reader.close()
      writer.deactivate(removeFile: true)
    }

    var bands = [Float](repeating: 0.2, count: LockScreenAudioSpectrumChannel.bandCount)
    let t0: UInt64 = 50_000_000_000
    XCTAssertTrue(writer.write(generation: 1, stereo: false, bands: bands, nowNanos: t0))
    XCTAssertEqual(reader.read(nowNanos: t0 + 200_000_000)?.generation, 1)
    XCTAssertEqual(reader.read(nowNanos: t0 + 200_000_000)?.stereo, false)

    // Beyond 250 ms staleness threshold returns nil.
    XCTAssertNil(reader.read(nowNanos: t0 + 300_000_000))

    // Deactivating unlinks the backing file and clears the mapping.
    writer.deactivate(removeFile: true)
    XCTAssertNil(reader.read(nowNanos: t0 + 310_000_000))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: LockScreenAudioSpectrumChannel.url(in: exchangeURL).path))

    // Recreating with a new inode is picked up automatically by the existing reader.
    bands[5] = 0.9
    let t1: UInt64 = 60_000_000_000
    XCTAssertTrue(writer.write(generation: 2, stereo: true, bands: bands, nowNanos: t1))
    let reopened = reader.read(nowNanos: t1 + 5_000_000)
    XCTAssertEqual(reopened?.generation, 2)
    XCTAssertEqual(reopened?.stereo, true)
    XCTAssertEqual(reopened?.bands[5] ?? 0, 0.9, accuracy: 1e-6)
  }

  // MARK: - LockScreenMediaExchange & LockScreenConfiguration

  func testMediaSnapshotTimelineInterpolationAndCodecNumbering() throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let playing = LockScreenMediaSnapshot(
      generation: 3,
      properties: .init(title: "Play Dice!", artist: "Hakos Baelz"),
      playbackState: SystemMediaPlaybackState.playing.rawValue,
      timeline: .init(position: 10, duration: 120, anchorWallTime: anchor.timeIntervalSince1970),
      thumbnail: .init(
        primaryColor: "rgb(255, 0, 128)",
        secondaryColor: "rgb(0, 255, 0)",
        tertiaryColor: "rgb(0, 0, 255)",
        textColor: "rgb(255, 255, 255)",
        highContrastColor: "rgb(255, 255, 255)",
        width: 2, height: 2, artworkRevision: 1, hasArtwork: true)
    )

    let at15 = try XCTUnwrap(playing.interpolatedTimeline(at: anchor.addingTimeInterval(15)))
    XCTAssertEqual(at15.position, 25, accuracy: 1e-6)
    XCTAssertEqual(at15.duration, 120, accuracy: 1e-6)

    // Clamps at duration when elapsed exceeds track length.
    let pastEnd = try XCTUnwrap(playing.interpolatedTimeline(at: anchor.addingTimeInterval(500)))
    XCTAssertEqual(pastEnd.position, 120, accuracy: 1e-6)

    // Paused holds position constant.
    var paused = playing
    paused.playbackState = SystemMediaPlaybackState.paused.rawValue
    let pausedLater = try XCTUnwrap(paused.interpolatedTimeline(at: anchor.addingTimeInterval(30)))
    XCTAssertEqual(pausedLater.position, 10, accuracy: 1e-6)

    // SceneScript playback state numbering differs from Web raw values.
    XCTAssertEqual(LockScreenMediaCodec.sceneScriptPlaybackState(fromWebRawState: 0), 1) // playing
    XCTAssertEqual(LockScreenMediaCodec.sceneScriptPlaybackState(fromWebRawState: 1), 2) // paused
    XCTAssertEqual(LockScreenMediaCodec.sceneScriptPlaybackState(fromWebRawState: 2), 0) // stopped

    let thumbJSON = try XCTUnwrap(LockScreenMediaCodec.sceneThumbnailJSON(try XCTUnwrap(playing.thumbnail)))
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(thumbJSON.utf8)) as? [String: Any])
    XCTAssertEqual(obj["type"] as? String, "mediaThumbnailChanged")
    XCTAssertEqual(obj["hasThumbnail"] as? Bool, true)
    let primary = try XCTUnwrap(obj["primaryColor"] as? [Double])
    XCTAssertEqual(primary.count, 3)
    XCTAssertEqual(primary[0], 1.0, accuracy: 1e-6)
    XCTAssertEqual(primary[1], 0.0, accuracy: 1e-6)
    XCTAssertEqual(primary[2], 128.0 / 255.0, accuracy: 1e-6)
  }

  func testLockScreenSceneBackwardCompatibilityAndRendererSharing() throws {
    let legacyJSON = """
      {
        "displayID": 1,
        "title": "Scene",
        "projectPath": "rev/project.json",
        "assetsPath": "rev/assets",
        "fps": 30,
        "scalingMode": 3,
        "scalingFactor": 1.0,
        "paused": false
      }
      """
    let decoded = try JSONDecoder().decode(LockScreenScene.self, from: Data(legacyJSON.utf8))
    XCTAssertNil(decoded.mediaIntegrationEnabled)
    XCTAssertNil(decoded.audioResponseEnabled)
    XCTAssertFalse(decoded.effectiveMediaIntegrationEnabled)
    XCTAssertFalse(decoded.effectiveAudioResponseEnabled)

    var enabled = decoded
    enabled.mediaIntegrationEnabled = true
    enabled.audioResponseEnabled = true
    XCTAssertTrue(enabled.effectiveMediaIntegrationEnabled)
    XCTAssertTrue(enabled.effectiveAudioResponseEnabled)
    XCTAssertTrue(
      decoded.sharesRenderer(with: enabled),
      "toggling media integration or audio response must update the running surface in place")

    // Plain videos never enable media or audio regardless of flags.
    var video = enabled
    video.plainVideo = true
    XCTAssertFalse(video.effectiveMediaIntegrationEnabled)
    XCTAssertFalse(video.effectiveAudioResponseEnabled)
  }

  // MARK: - LockScreenLiveFeedCoordinator

  func testCoordinatorLifecycleSleepExitAndZeroDiskThrashTimeline() async throws {
    let provider = FakeLiveMediaProvider()
    let session = DesktopMediaSession(provider: provider)
    var canDeliver = true
    var displaysAsleep = false
    var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    let currentNanos: UInt64 = 1_000_000_000
    var alivePIDs: Set<Int32> = [4242]
    var exitHandlers: [Int32: @MainActor () -> Void] = [:]
    var demandNotifyHandler: (@MainActor () -> Void)?
    var sleepHandler: (@MainActor (Bool) -> Void)?
    var mediaNotifications = 0
    var bridgeAudioDemands: [Bool] = []
    var currentSpectrum: BridgeAudioSpectrumFull?

    let coordinator = LockScreenLiveFeedCoordinator(
      exchange: exchangeURL,
      session: session,
      canDeliver: { canDeliver },
      displaysAsleep: { displaysAsleep },
      setAudioDemand: { active in bridgeAudioDemands.append(active) },
      readAudioSpectrum: { currentSpectrum },
      isProcessAlive: { alivePIDs.contains($0) },
      watchProcessExit: { pid, onExit in
        exitHandlers[pid] = onExit
        return { exitHandlers.removeValue(forKey: pid) }
      },
      observeDemandNotification: { handler in
        demandNotifyHandler = handler
        return { demandNotifyHandler = nil }
      },
      postMediaChanged: { mediaNotifications += 1 },
      observeWorkspaceSleep: { handler in
        sleepHandler = handler
        return { sleepHandler = nil }
      },
      now: { currentDate },
      nowNanos: { currentNanos },
      audioInterval: .seconds(60)
    )
    defer { coordinator.shutdown() }

    coordinator.start()
    XCTAssertFalse(coordinator.mediaActive)
    XCTAssertFalse(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(bridgeAudioDemands, [])

    // Pre-populate provider state as if a desktop consumer had already seen a track.
    let desktopKey = ObjectIdentifier(self)
    session.relay.setConsuming(true, for: desktopKey)
    let png = try makeSolidPNG(255, 40, 80, size: 2)
    let thumb = SystemMediaThumbnail(
      pngBase64DataURL: "data:image/png;base64," + png.base64EncodedString(),
      primaryColor: "rgb(255, 40, 80)",
      secondaryColor: "rgb(10, 20, 30)",
      tertiaryColor: "rgb(40, 50, 60)",
      textColor: "rgb(255, 255, 255)",
      highContrastColor: "rgb(255, 255, 255)",
      rgba: [UInt8](repeating: 200, count: 2 * 2 * 4),
      width: 2, height: 2
    )
    provider.onPropertiesChanged?(SystemMediaProperties(title: "PLAY DICE!", artist: "Bae"))
    provider.onThumbnailChanged?(thumb)
    provider.onPlaybackChanged?(.playing)
    provider.onTimelineChanged?(SystemMediaTimeline(position: 12, duration: 180))
    // Desktop pauses when locked -> desktop consumer drops.
    session.relay.setConsuming(false, for: desktopKey)
    XCTAssertEqual(provider.consumers, 0)

    // Extension publishes demand for both media and audio.
    try writeDemand(LockScreenLiveDemand(processID: 4242, needsMedia: true, needsAudio: true))
    demandNotifyHandler?()
    try await Task.sleep(for: .milliseconds(30))

    XCTAssertTrue(coordinator.mediaActive)
    XCTAssertTrue(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 1)
    XCTAssertEqual(bridgeAudioDemands, [true])

    // Provider replays track after attach -> exchange snapshot + artwork files written.
    provider.onPropertiesChanged?(SystemMediaProperties(title: "PLAY DICE!", artist: "Bae"))
    provider.onThumbnailChanged?(thumb)
    provider.onPlaybackChanged?(.playing)
    provider.onTimelineChanged?(SystemMediaTimeline(position: 12, duration: 180))

    let snapshot = try XCTUnwrap(LockScreenMediaSnapshot.read(from: exchangeURL))
    XCTAssertEqual(snapshot.properties.title, "PLAY DICE!")
    XCTAssertEqual(snapshot.properties.artist, "Bae")
    XCTAssertEqual(snapshot.playbackState, SystemMediaPlaybackState.playing.rawValue)
    XCTAssertEqual(snapshot.thumbnail?.hasArtwork, true)
    let rgba = LockScreenMediaSnapshot.readArtworkRGBA(
      from: exchangeURL, thumbnail: try XCTUnwrap(snapshot.thumbnail))
    XCTAssertEqual(rgba?.count, 16)
    let pngURL = LockScreenMediaSnapshot.readArtworkPNGDataURL(
      from: exchangeURL, thumbnail: try XCTUnwrap(snapshot.thumbnail))
    XCTAssertTrue(pngURL.hasPrefix("data:image/png;base64,"))

    // Ordinary 1 Hz timeline ticks within 1.5 s must NOT write to disk or post notifications.
    let writesBeforeTicks = mediaNotifications
    let generationBeforeTicks = snapshot.generation
    for second in 1...10 {
      currentDate = currentDate.addingTimeInterval(1)
      provider.onTimelineChanged?(SystemMediaTimeline(position: 12 + Double(second), duration: 180))
    }
    XCTAssertEqual(mediaNotifications, writesBeforeTicks)
    XCTAssertEqual(LockScreenMediaSnapshot.read(from: exchangeURL)?.generation, generationBeforeTicks)

    // A genuine user seek (> 1.5 s jump) DOES write once and notifies.
    provider.onTimelineChanged?(SystemMediaTimeline(position: 95, duration: 180))
    XCTAssertEqual(mediaNotifications, writesBeforeTicks + 1)
    let afterSeek = try XCTUnwrap(LockScreenMediaSnapshot.read(from: exchangeURL))
    XCTAssertEqual(afterSeek.generation, generationBeforeTicks + 1)
    XCTAssertEqual(afterSeek.timeline?.position ?? -1, 95, accuracy: 1e-6)

    // Pump audio spectrum into shared memory and verify reader sees unclamped bands.
    var bands = [Float](repeating: 0, count: LockScreenAudioSpectrumChannel.bandCount)
    bands[0] = 1.4
    bands[128] = 0.85
    currentSpectrum = BridgeAudioSpectrumFull(generation: 11, stereo: true, bands: bands)
    coordinator.pumpAudioOnce()
    let reader = LockScreenAudioSpectrumReader(exchange: exchangeURL)
    defer { reader.close() }
    let audioFrame = try XCTUnwrap(reader.read(nowNanos: currentNanos + 5_000_000))
    XCTAssertEqual(audioFrame.generation, 11)
    XCTAssertEqual(audioFrame.bands[0], 1.4, accuracy: 1e-6)
    XCTAssertEqual(audioFrame.bands[128], 0.85, accuracy: 1e-6)

    // Display sleep immediately drops both media and audio feeds and deletes exchange files.
    sleepHandler?(true)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(coordinator.mediaActive)
    XCTAssertFalse(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(bridgeAudioDemands, [true, false])
    XCTAssertNil(LockScreenMediaSnapshot.read(from: exchangeURL))
    XCTAssertNil(reader.read(nowNanos: currentNanos + 10_000_000))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: LockScreenAudioSpectrumChannel.url(in: exchangeURL).path))

    // Display wake while demand is still present brings both back.
    sleepHandler?(false)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(coordinator.mediaActive)
    XCTAssertTrue(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 1)
    XCTAssertEqual(bridgeAudioDemands, [true, false, true])

    // Synchronous display-sleep probe also stops both feeds even without a workspace notice.
    displaysAsleep = true
    coordinator.reconcile()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(coordinator.mediaActive)
    XCTAssertFalse(coordinator.audioActive)
    displaysAsleep = false
    coordinator.reconcile()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(coordinator.mediaActive)
    XCTAssertTrue(coordinator.audioActive)

    // Disabling lock screen / user pause (`canDeliver = false`) stops both immediately.
    canDeliver = false
    coordinator.reconcile()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(coordinator.mediaActive)
    XCTAssertFalse(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(bridgeAudioDemands.last, false)

    // Re-enabling brings them back; then extension process exit stops both immediately.
    canDeliver = true
    coordinator.reconcile()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(coordinator.mediaActive)
    XCTAssertTrue(coordinator.audioActive)

    alivePIDs.remove(4242)
    exitHandlers[4242]?()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(coordinator.mediaActive)
    XCTAssertFalse(coordinator.audioActive)
    XCTAssertEqual(provider.consumers, 0)
    XCTAssertEqual(bridgeAudioDemands.last, false)
  }

  func testCoordinatorReplaysAlreadyActiveDesktopMediaWithoutWaitingForTrackChange() throws {
    let provider = FakeLiveMediaProvider()
    let session = DesktopMediaSession(provider: provider)
    var demandNotifyHandler: (@MainActor () -> Void)?

    // Desktop consumer keeps relay populated before lock-screen demand arrives.
    let desktopKey = ObjectIdentifier(self)
    session.relay.setConsuming(true, for: desktopKey)
    provider.onPropertiesChanged?(SystemMediaProperties(title: "Still Playing", artist: "Artist"))
    provider.onPlaybackChanged?(.playing)
    provider.onTimelineChanged?(SystemMediaTimeline(position: 42, duration: 200))

    let coordinator = LockScreenLiveFeedCoordinator(
      exchange: exchangeURL,
      session: session,
      canDeliver: { true },
      displaysAsleep: { false },
      setAudioDemand: { _ in },
      readAudioSpectrum: { nil },
      isProcessAlive: { $0 == 9001 },
      watchProcessExit: { _, _ in {} },
      observeDemandNotification: { handler in
        demandNotifyHandler = handler
        return { demandNotifyHandler = nil }
      },
      postMediaChanged: {},
      observeWorkspaceSleep: { _ in {} }
    )
    defer {
      coordinator.shutdown()
      session.relay.setConsuming(false, for: desktopKey)
    }

    coordinator.start()
    try writeDemand(LockScreenLiveDemand(processID: 9001, needsMedia: true, needsAudio: false))
    demandNotifyHandler?()

    let snapshot = try XCTUnwrap(LockScreenMediaSnapshot.read(from: exchangeURL))
    XCTAssertEqual(snapshot.properties.title, "Still Playing")
    XCTAssertEqual(snapshot.properties.artist, "Artist")
    XCTAssertEqual(snapshot.playbackState, SystemMediaPlaybackState.playing.rawValue)
    XCTAssertEqual(snapshot.timeline?.position ?? -1, 42, accuracy: 1e-6)
  }

  private func writeDemand(_ demand: LockScreenLiveDemand) throws {
    let data = try JSONEncoder().encode(demand)
    try data.write(
      to: exchangeURL.appendingPathComponent(LockScreenLiveDemand.fileName), options: .atomic)
  }
}

@MainActor
private final class FakeLiveMediaProvider: SystemMediaProvider {
  let availability: SystemMediaAvailability = .available
  var onPropertiesChanged: ((SystemMediaProperties) -> Void)?
  var onThumbnailChanged: ((SystemMediaThumbnail) -> Void)?
  var onPlaybackChanged: ((SystemMediaPlaybackState) -> Void)?
  var onTimelineChanged: ((SystemMediaTimeline?) -> Void)?

  private(set) var consumers = 0

  func addConsumer() { consumers += 1 }
  func removeConsumer() { consumers = max(0, consumers - 1) }
  func replayCurrentState() {}
}
