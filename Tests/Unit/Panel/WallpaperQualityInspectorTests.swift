import XCTest

@testable import WallpaperMachine

/// Verifies Phase 1 per-wallpaper quality overrides in the Inspector (render scale + scene quality,
/// reset to global settings, one-click "Lower quality" action for High energy rating) and cached
/// post-download/import compatibility badge presentation.
@MainActor
final class WallpaperQualityInspectorTests: PanelTestCase {
  func testInspectorOptionsExposesPerWallpaperQualityCapabilitiesByKind() {
    let customQuality = BridgeSceneQuality(
      msaa: .x2, shadows: .low, volumetrics: .off, reflections: false, postProcessing: .disabled)

    let scene = InspectorOptions.make(
      BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene,
        renderScaleOverride: 0.75, sceneQualityOverride: customQuality),
      inputs: .init(globalRenderScale: 1.0, globalSceneQuality: .wallpaperEngineDefault))
    XCTAssertTrue(scene.offersRenderScaleOverride)
    XCTAssertTrue(scene.offersSceneQualityOverride)
    XCTAssertTrue(scene.offersQualityOverrides)
    XCTAssertTrue(scene.hasQualityOverride)
    XCTAssertEqual(scene.chosenRenderScale, 0.75)
    XCTAssertEqual(scene.chosenSceneQuality, customQuality)

    let web = InspectorOptions.make(
      BridgeSnapshotFixtures.options(wallpaperId: "web-1", kind: .webpage),
      inputs: .init(globalRenderScale: 0.75))
    XCTAssertTrue(web.offersRenderScaleOverride)
    XCTAssertFalse(web.offersSceneQualityOverride)
    XCTAssertTrue(web.offersQualityOverrides)
    XCTAssertFalse(web.hasQualityOverride)
    XCTAssertEqual(web.chosenRenderScale, 0.75)

    let video = InspectorOptions.make(
      BridgeSnapshotFixtures.options(wallpaperId: "vid-1", kind: .video))
    XCTAssertFalse(video.offersRenderScaleOverride)
    XCTAssertFalse(video.offersSceneQualityOverride)
    XCTAssertFalse(video.offersQualityOverrides)
  }

  func testPerWallpaperQualityOverridesResetAndOneClickLowerQuality() async throws {
    try await withPanel { panel in
      let store = panel.store
      let bridge = panel.bridge
      let options = BridgeSnapshotFixtures.options(wallpaperId: "heavy-scene", kind: .projectScene)
      store.appSnapshot.selectedWallpaperId = "heavy-scene"
      store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "heavy-scene", title: "Heavy Scene", kind: .projectScene, supported: true,
          active: true, selected: true, previewPath: nil)
      ]
      store.wallpaperOptionsSnapshot = options
      bridge.options["heavy-scene"] = options
      bridge.snapshot = BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)

      // One-click "Lower quality" steps render scale down to 0.75 and eases heavy scene quality.
      try await panel.controller.lowerWallpaperQuality(for: "heavy-scene")
      XCTAssertEqual(bridge.wallpaperRenderScaleCalls.last?.wallpaperId, "heavy-scene")
      XCTAssertEqual(bridge.wallpaperRenderScaleCalls.last?.scale, 0.75)
      XCTAssertEqual(
        bridge.wallpaperSceneQualityCalls.last?.quality,
        BridgeSceneQuality(
          msaa: .off, shadows: .low, volumetrics: .low, reflections: false, postProcessing: .enabled))

      // A second click steps render scale further down to 0.5.
      try await panel.controller.lowerWallpaperQuality(for: "heavy-scene")
      XCTAssertEqual(bridge.wallpaperRenderScaleCalls.last?.scale, 0.5)

      // When already below 50% (e.g. 25%), "Lower quality" must NEVER raise render scale up to 50%.
      XCTAssertEqual(PanelController.loweredRenderScale(from: 1.0), 0.75)
      XCTAssertEqual(PanelController.loweredRenderScale(from: 0.75), 0.5)
      XCTAssertEqual(PanelController.loweredRenderScale(from: 0.5), 0.5)
      XCTAssertEqual(PanelController.loweredRenderScale(from: 0.25), 0.25)
      try await panel.controller.setWallpaperRenderScale(0.25, for: "heavy-scene")
      let callsBeforeLowClick = bridge.wallpaperRenderScaleCalls.count
      try await panel.controller.lowerWallpaperQuality(for: "heavy-scene")
      XCTAssertEqual(
        bridge.wallpaperRenderScaleCalls.count, callsBeforeLowClick,
        "Lower quality must not write a higher render scale when already at 0.25")
      XCTAssertEqual(store.wallpaperOptionsSnapshot?.renderScaleOverride, 0.25)

      // Reset clears both overrides back to nil ("Use global setting").
      try await panel.controller.resetWallpaperQuality(for: "heavy-scene")
      XCTAssertNil(bridge.wallpaperRenderScaleCalls.last?.scale)
      XCTAssertNil(bridge.wallpaperSceneQualityCalls.last?.quality)
      XCTAssertNil(store.wallpaperOptionsSnapshot?.renderScaleOverride)
      XCTAssertNil(store.wallpaperOptionsSnapshot?.sceneQualityOverride)
    }
  }

  func testCompatibilityCardShowsCachedBadgeWithoutRunningManualCheck() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("panel-compat-badge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = root.appendingPathComponent("Library", isDirectory: true)
    let dir = lib.appendingPathComponent("clip-1", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"type":"video","title":"Clip","file":"clip.mp4"}"#.utf8)
      .write(to: dir.appendingPathComponent("project.json"))
    try Data("bytes".utf8).write(to: dir.appendingPathComponent("clip.mp4"))

    let cache = WallpaperCompatibilityCache(
      file: root.appendingPathComponent("Cache/CompatibilityCache.json"),
      library: { lib },
      assetsURL: { root.appendingPathComponent("Assets", isDirectory: true) },
      appVersion: { "1.0 (1)" },
      service: WallpaperCompatibilityService(
        libraryURL: lib,
        assetsURL: { root.appendingPathComponent("Assets", isDirectory: true) },
        probe: { _ in .probed(NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: true)) }
      )
    )
    let cacheStore = WallpaperCompatibilityCacheStore(cache: cache)

    try await withPanel { panel in
      let entry = BridgeWallpaperEntry(
        id: "clip-1", title: "Clip", kind: .video, supported: true,
        active: false, selected: true, previewPath: nil)
      panel.store.compatibilityCache = cacheStore
      panel.store.appSnapshot.selectedWallpaperId = "clip-1"
      panel.store.librarySnapshot.wallpapers = [entry]
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "clip-1", kind: .video)

      cacheStore.schedulePrecheck(wallpaperIDs: ["clip-1"], entries: [entry], libraryRevision: 0)
      await cacheStore.drainForTests()

      let state = try XCTUnwrap(panel.controller.compatibilityState)
      XCTAssertTrue(state.checks.isEmpty)
      XCTAssertEqual(state.cachedSummary?.status, .ok)
      XCTAssertEqual(InspectorWording.compatibilitySummary(state), L("Pre-checked: OK"))
    }
  }
}
